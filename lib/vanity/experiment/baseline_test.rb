require "vanity/experiment/version"

module Vanity
  module Experiment
    class BaselineTest < Base
      class << self
        def friendly_name
          "Baseline Test"
        end
      end

      # -- Enabled --
      #
      # Returns true if experiment active, false if completed.
      def active?
        true
      end

      # Returns true if experiment is enabled, false if disabled.
      def enabled?
        !@playground.collecting? || (active? && connection.is_experiment_enabled?(id))
      end

      # Time stamp when experiment was created.
      def created_at
        @created_at ||= connection.get_experiment_created_at(id)
      end

      # Enable or disable the experiment. Only works if the playground is collecting
      # and this experiment is enabled.
      #
      # **Note** You should *not* set the enabled/disabled status of an
      # experiment until it exists in the database. Ensure that your experiment
      # has had #save invoked previous to any enabled= calls.
      def enabled=(bool)
        return unless @playground.collecting? && active?
        if created_at.nil?
          Vanity.logger.warn( 
            'DB has no created_at for this experiment! This most likely means' + 
            'you didn\'t call #save before calling enabled=, which you should.'
          )
        else
          connection.set_experiment_enabled(id, bool)
        end
      end

      # -- Store/validate --

      # Get rid of all experiment data.
      def destroy
        connection.destroy_experiment id
        @created_at = @completed_at = nil
      end

      # -- Metric --

      # Tells Baseline test which metric we're measuring, or returns metric in use.
      #
      # @example Define Baseline test against coolness metric
      #   baseline_test "Background color" do
      #     metrics :coolness
      #   end
      # @example Find metric for Baseline test
      #   puts "Measures: " + experiment(:background_color).metrics.map(&:name)
      def metrics(*args)
        @metrics = args.map { |id| @playground.metric(id) } unless args.empty?
        @metrics
      end

      # Chooses a value for this experiment. You probably want to use the
      # Rails helper method baseline_test instead.
      #
      # This doesn't actually do anything for a tracking experiment. This
      # method is simply for consistency sake.
      #
      # @example
      #   color = experiment(:which_blue).choose
      def choose(request=nil)
        if @playground.collecting?
          if active?
            if enabled?
              return assignment_for_identity(request)
            end
          end
        end

        true
      end

      # clears all collected data for the experiment
      def reset
        return unless @playground.collecting?
        connection.destroy_experiment(id)
        connection.set_experiment_created_at(id, Time.now)
        @outcome = @completed_at = nil
        self
      end

      # clears all collected data for the experiment
      def reset
        connection.destroy_experiment(id)
        connection.set_experiment_created_at(id, Time.now)
        @outcome = @completed_at = nil
        self
      end

      # Set up tracking for metrics and ensure that the attributes of the ab_test
      # are valid (e.g. has alternatives, has a default, has metrics).
      # If collecting, this method will also store this experiment into the db.
      # In most cases, you call this method right after the experiment's been instantiated
      # and declared.
      def save
        if @saved
          Vanity.logger.warn("Experiment #{name} has already been saved")
          return
        end
        @saved = true
        super
        if @metrics.nil? || @metrics.empty?
          Vanity.logger.warn("Please use metrics method to explicitly state which metric you are measuring against.")
          metric = @playground.metrics[id] ||= Vanity::Metric.new(@playground, name)
          @metrics = [metric]
        end
        @metrics.each do |metric|
          metric.hook(&method(:track!))
        end
      end

      # Called via a hook by the associated metric.
      def track!(metric_id, timestamp, count, *args)
        return unless active? && enabled?
        identity = args.last[:identity] if args.last.is_a?(Hash)
        identity ||= identity() rescue nil
        if identity
          connection.ab_add_conversion(id, 0, identity, count)
        end
      end

      def alternative
        Alternative.new( self, nil, 0 )
      end

      # Number of participants who viewed this alternative.
      def participants
        alternative.participants
      end

      # Number of participants who converted on this alternative (a
      # participant is counted only once).
      def converted
        alternative.converted
      end

      # Number of conversions for this alternative (same participant may be
      # counted more than once).
      def conversions
        alternative.conversions
      end

      # Conversion rate calculated as converted/participants
      def conversion_rate
        @conversion_rate ||= (participants > 0 ? converted.to_f/participants.to_f  : 0.0)
      end

      # Rolling 7 day conversion rate
      def data
        @data ||= connection.ab_rolling_conversion_rates( id )
      end

    protected

      # Returns the assigned alternative, previously chosen alternative, or
      # alternative_for for a given identity.  
      def assignment_for_identity(request)
        identity = identity()
        if filter_visitor?( request, identity )
          true
        else
          index = connection.ab_assigned(id, identity)
          unless index
            save_assignment(identity, 0, request) unless @playground.using_js?
          end
          true
        end
      end

      # Saves the assignment of an alternative to a person and performs the
      # necessary housekeeping. Ignores repeat identities and filters using
      # Playground#request_filter.
      def save_assignment(identity, index, request)
        return if index == connection.ab_showing(id, identity)
        connection.ab_add_participant(id, index, identity)
      end

      def filter_visitor?(request, identity)
        @playground.request_filter.call(request) || 
          (@request_filter_block && @request_filter_block.call(request, identity))
      end

      def load_counts
        if @playground.collecting?
          @participants, @converted, @conversions = @playground.connection.ab_counts(id, nil).values_at(:participants, :converted, :conversions)
        else
          @participants = @converted = @conversions = 0
        end
      end
    end

    module Definition
      # Define an Baseline test with the given name. For example:
      #   baseline_test "New Banner" do
      #     metrics :red, :green, :blue
      #   end
      def baseline_test(name, &block)
        define name, :baseline_test, &block
      end
    end

  end
end
