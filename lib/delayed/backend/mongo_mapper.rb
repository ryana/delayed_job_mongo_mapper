module Delayed
  module Backend
    module MongoMapper
      class Job
        include ::MongoMapper::Document
        include Delayed::Backend::Base
        set_collection_name 'delayed_jobs'

        key :priority,    Integer, :default => 0
        key :attempts,    Integer, :default => 0
        key :handler,     String
        key :run_at,      Time
        key :locked_at,   Time
        key :locked_by,   String    #,  :index => true
        key :failed_at,   Time
        key :last_error,  String
        timestamps!

        #ensure_index [[:priority, 1], [:run_at, 1]]

        before_save :set_default_run_at

        def self.before_fork
          ::MongoMapper.connection.close
        end

        def self.after_fork
          ::MongoMapper.connection.connect
        end

        def self.db_time_now
          Time.now.utc
        end

        def self.find_available(worker_name, limit = 5, max_run_time = Worker.max_run_time)
          right_now = db_time_now

          conditions = {
            :run_at => {"$lte" => right_now},
            :limit => -limit, # In mongo, positive limits are 'soft' and negative are 'hard'
            :failed_at => nil,
            :sort => [[:priority, 1], [:run_at, 1]]
          }

          #where = "this.locked_at == null || this.locked_at < #{make_date(right_now - max_run_time)}"
          ors = [
            {:locked_at => nil},
            {:locked_at => {'$lt' => (right_now - max_run_time)}}
          ]

          (conditions[:priority] ||= {})['$gte'] = Worker.min_priority.to_i if Worker.min_priority
          (conditions[:priority] ||= {})['$lte'] = Worker.max_priority.to_i if Worker.max_priority

          @@skipped_locked_times ||= 0
          # When the queue gets large, this can take a while. Lets only get locked jobs
          # every Nth time, since they will be rare anyway.  When the queue is small,
          # this won't introduce too much of a delay processing jobs.
          if @@skipped_locked_times.to_i > 10
            results = all(conditions.merge(:locked_by => worker_name))
          else
            @@skipped_locked_times += 1
            results = []
          end

          #results += all(conditions.merge('$where' => where)) if results.size < limit
          results += all(conditions.merge('$or' => ors)) if results.size < limit

          results
        end

        # When a worker is exiting, make sure we don't have any locked jobs.
        def self.clear_locks!(worker_name)
          collection.update({:locked_by => worker_name}, {"$set" => {:locked_at => nil, :locked_by => nil}}, :multi => true)
        end

        # Lock this job for this worker.
        # Returns true if we have the lock, false otherwise.
        def lock_exclusively!(max_run_time, worker = worker_name)
          right_now = self.class.db_time_now
          overtime = right_now - max_run_time.to_i

          #query = "this.locked_at == null || this.locked_at < #{make_date(overtime)} || this.locked_by == #{worker.to_json}"
          ors = [
            {:locked_at => nil},
            {:locked_at => {'$lt' => overtime}},
            {:locked_by => worker}
          ]
          
          #conditions = {:_id => id, :run_at => {"$lte" => right_now}, "$where" => query}
          conditions = {:_id => id, :run_at => {"$lte" => right_now}, "$or" => ors}

          collection.update(conditions, {"$set" => {:locked_at => right_now, :locked_by => worker}})
          affected_rows = self.collection.find({:_id => id, :locked_by => worker}).count
          if affected_rows == 1
            self.locked_at = right_now
            self.locked_by = worker
            return true
          else
            return false
          end
        end

        private
          def self.make_date(date_or_seconds)
            "new Date(#{date_or_seconds.to_f * 1000})"
          end

          def make_date(date)
            self.class.make_date(date)
          end
      end
    end
  end
end
