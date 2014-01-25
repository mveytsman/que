require 'socket'

module Que
  class Locker
    attr_reader :thread, :workers

    def initialize(options = {})
      @queue_name = options[:queue] || ''
      @listening  = !!options[:listening]

      @job_queue    = JobQueue.new
      @result_queue = ResultQueue.new

      @workers = (options[:worker_count] || 4).times.map do
        Worker.new :job_queue    => @job_queue,
                   :result_queue => @result_queue
      end

      @thread = Thread.new { work_loop }
    end

    def stop
      @stop = true
      @thread.join
    end

    private

    def work_loop
      Que.adapter.checkout do |connection|
        backend_pid = Que.execute("SELECT pg_backend_pid()").first[:pg_backend_pid].to_i

        begin
          Que.execute "LISTEN que_locker_#{backend_pid}" if @listening

          # A previous locker that didn't exit cleanly may have left behind
          # a bad locker record, so clean up before registering.
          Que.execute :clean_lockers
          Que.execute :register_locker, [@queue_name, @workers.count, Process.pid, Socket.gethostname, @listening]

          loop do
            connection.wait_for_notify(0.001) do |channel, pid, payload|
              pk = Que.indifferentiate(JSON_MODULE.load(payload))
              @job_queue.push(pk) if lock_job?(pk[:job_id])
            end

            while id = @result_queue.shift
              Que.execute "SELECT pg_advisory_unlock($1)", [id]
            end

            break if @stop
          end
        ensure
          Que.execute "UNLISTEN *"
          Que.execute "DELETE FROM que_lockers WHERE pid = $1", [backend_pid]

          # Get rid of the remaining notifications before returning the connection to the pool.
          {} while connection.notifies
        end
      end
    end

    private

    def lock_job?(id)
      Que.execute("SELECT pg_try_advisory_lock($1)", [id.to_i]).first[:pg_try_advisory_lock] == 't'
    end
  end
end
