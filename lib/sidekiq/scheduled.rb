# frozen_string_literal: true

require "sidekiq"
require "sidekiq/util"
require "sidekiq/api"

module Sidekiq
  module Scheduled
    SETS = %w[retry schedule]

    class Enq
      def enqueue_jobs(now = Time.now.to_f.to_s, sorted_sets = SETS)
        # A job's "score" in Redis is the time at which it should be processed.
        # Just check Redis for the set of jobs with a timestamp before now.
        Sidekiq.redis do |conn|
          sorted_sets.each do |sorted_set|
            # Get next items in the queue with scores (time to execute) <= now.
            counter = 0
            offset = 0
            until (jobs = conn.zrangebyscore(sorted_set, "-inf", now, limit: [offset, 100])).empty?
              # We need to go through the list one at a time to reduce the risk of something
              # going wrong between the time jobs are popped from the scheduled queue and when
              # they are pushed onto a work queue and losing the jobs.
              counter = 0
              jobs.each do |job|
                # Pop item off the queue and add it to the work queue. If the job can't be popped from
                # the queue, it's because another process already popped it so we can move on to the
                # next one.
                if conn.zrem(sorted_set, job)
                  Sidekiq::Client.push(Sidekiq.load_json(job))
                  Sidekiq.logger.debug { "enqueued #{sorted_set}: #{job}" }
                else
                  counter += 1
                end
              end

              if counter > 70
                #
                # у нас тут больше 50 zrem пролетело - высокий конкаренси надо прыгать и фетчить с другого места
                # иначе помрем

                # говорят zcount очень эффективна
                # более того мы выполним ее всего 1 раз и дальше уже с новым офсетом конфликтов быть не должно
                # пока не высосем ВСЮ очередь
                queue_length = conn.zcount(sorted_set, "-inf", now)

                if queue_length < 1000
                  # и так должно отработать хорошо
                  offset = 0
                else
                  # нет смысла уходить дальше чем 10_000 какая бы жирная очередь не была
                  # это число выбранно эмпирически
                  # но чем больше у вас сайдкиков тем больше число
                  max_offset = [queue_length / 2, 10_000].min
                end

                offset = (0..max_offset).to_a.sample
              end
            end
          end
        end
      end
    end

    def x
      Sidekiq.redis do |conn|
        sorted_set = 'schedule'
        # Get next items in the queue with scores (time to execute) <= now.
        counter = 0
        offset = 0
        until (jobs = conn.zrangebyscore(sorted_set, "-inf", Time.now.to_f.to_s, limit: [offset, 100])).empty?
          puts "offset=#{offset}"
          counter = 0
          jobs.each do |job|
            if conn.zrem(sorted_set, job)
              Sidekiq::Client.push(Sidekiq.load_json(job))
            else
              counter += 1
            end
          end
          if counter > 50
            offset = (200..10000).to_a.sample
          end
        end
      end
    end

    ##
    # The Poller checks Redis every N seconds for jobs in the retry or scheduled
    # set have passed their timestamp and should be enqueued.  If so, it
    # just pops the job back onto its original queue so the
    # workers can pick it up like any other job.
    class Poller
      include Util

      INITIAL_WAIT = 10

      def initialize
        @enq = (Sidekiq.options[:scheduled_enq] || Sidekiq::Scheduled::Enq).new
        @sleeper = ConnectionPool::TimedStack.new
        @done = false
        @thread = nil
      end

      # Shut down this instance, will pause until the thread is dead.
      def terminate
        @done = true
        if @thread
          t = @thread
          @thread = nil
          @sleeper << 0
          t.value
        end
      end

      def start
        @thread ||= safe_thread("scheduler") {
          initial_wait

          until @done
            enqueue
            wait
          end
          Sidekiq.logger.info("Scheduler exiting...")
        }
      end

      def enqueue
        @enq.enqueue_jobs
      rescue => ex
        # Most likely a problem with redis networking.
        # Punt and try again at the next interval
        logger.error ex.message
        handle_exception(ex)
      end

      private

      def wait
        @sleeper.pop(random_poll_interval)
      rescue Timeout::Error
        # expected
      rescue => ex
        # if poll_interval_average hasn't been calculated yet, we can
        # raise an error trying to reach Redis.
        logger.error ex.message
        handle_exception(ex)
        sleep 5
      end

      def random_poll_interval
        # We want one Sidekiq process to schedule jobs every N seconds.  We have M processes
        # and **don't** want to coordinate.
        #
        # So in N*M second timespan, we want each process to schedule once.  The basic loop is:
        #
        # * sleep a random amount within that N*M timespan
        # * wake up and schedule
        #
        # We want to avoid one edge case: imagine a set of 2 processes, scheduling every 5 seconds,
        # so N*M = 10.  Each process decides to randomly sleep 8 seconds, now we've failed to meet
        # that 5 second average. Thankfully each schedule cycle will sleep randomly so the next
        # iteration could see each process sleep for 1 second, undercutting our average.
        #
        # So below 10 processes, we special case and ensure the processes sleep closer to the average.
        # In the example above, each process should schedule every 10 seconds on average. We special
        # case smaller clusters to add 50% so they would sleep somewhere between 5 and 15 seconds.
        # As we run more processes, the scheduling interval average will approach an even spread
        # between 0 and poll interval so we don't need this artifical boost.
        #
        if process_count < 10
          # For small clusters, calculate a random interval that is ±50% the desired average.
          poll_interval_average * rand + poll_interval_average.to_f / 2
        else
          # With 10+ processes, we should have enough randomness to get decent polling
          # across the entire timespan
          poll_interval_average * rand
        end
      end

      # We do our best to tune the poll interval to the size of the active Sidekiq
      # cluster.  If you have 30 processes and poll every 15 seconds, that means one
      # Sidekiq is checking Redis every 0.5 seconds - way too often for most people
      # and really bad if the retry or scheduled sets are large.
      #
      # Instead try to avoid polling more than once every 15 seconds.  If you have
      # 30 Sidekiq processes, we'll poll every 30 * 15 or 450 seconds.
      # To keep things statistically random, we'll sleep a random amount between
      # 225 and 675 seconds for each poll or 450 seconds on average.  Otherwise restarting
      # all your Sidekiq processes at the same time will lead to them all polling at
      # the same time: the thundering herd problem.
      #
      # We only do this if poll_interval_average is unset (the default).
      def poll_interval_average
        Sidekiq.options[:poll_interval_average] ||= scaled_poll_interval
      end

      # Calculates an average poll interval based on the number of known Sidekiq processes.
      # This minimizes a single point of failure by dispersing check-ins but without taxing
      # Redis if you run many Sidekiq processes.
      def scaled_poll_interval
        process_count * Sidekiq.options[:average_scheduled_poll_interval]
      end

      def process_count
        pcount = Sidekiq::ProcessSet.new.size
        pcount = 1 if pcount == 0
        pcount
      end

      def initial_wait
        # Have all processes sleep between 5-15 seconds.  10 seconds
        # to give time for the heartbeat to register (if the poll interval is going to be calculated by the number
        # of workers), and 5 random seconds to ensure they don't all hit Redis at the same time.
        total = 0
        total += INITIAL_WAIT unless Sidekiq.options[:poll_interval_average]
        total += (5 * rand)

        @sleeper.pop(total)
      rescue Timeout::Error
      end
    end
  end
end
