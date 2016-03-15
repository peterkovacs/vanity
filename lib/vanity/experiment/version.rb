module Vanity
  module Experiment
    class Version
      # Human readable experiment version name.
      attr_reader :name
      alias :to_s :name

      # Unique identifier, derived from name experiment name, e.g. "Green
      # Button" becomes :green_button.
      attr_reader :id

      attr_reader :experiment
      
      attr_reader :version

      def initialize( experiment, version )
        if version
          @id = "#{experiment.unversioned_id}_v#{version}".to_sym
          @name = "#{experiment.unversioned_name} v#{version}"
        else
          @id = experiment.unversioned_id
          @name = experiment.unversioned_name
        end
        @experiment = experiment
        @version = version
      end

      def default?
        @version.nil?
      end

      # Time stamp when experiment was created.
      def created_at
        @created_at ||= connection.get_experiment_created_at(@id)
      end

      # Returns the type of this experiment as a symbol (e.g. :ab_test).
      def type
        experiment.type
      end

      # Alternative chosen when this experiment completed.
      def outcome
        return unless playground.collecting?
        outcome = connection.ab_get_outcome(id)
        outcome && alternatives[outcome]
      end

      # Force experiment version to complete.
      # @param optional integer id of the alternative that is the decided
      # outcome of the experiment
      def complete!(outcome = nil)
        playground.logger.info "vanity: completed experiment #{id}"
        return unless playground.collecting?
        connection.set_experiment_completed_at @id, Time.now
        @completed_at = connection.get_experiment_completed_at(@id)
      end

      # Time stamp when experiment version was completed.
      def completed_at
        @completed_at ||= connection.get_experiment_completed_at(@id)
      end
      
      # Returns true if experiment active, false if completed.
      def active?
        !playground.collecting? || !connection.is_experiment_completed?(id)
      end

      def enabled?
        !playground.collecting? || ( active? && connection.is_experiment_enabled?(id) )
      end

      # -- Completion --

      # Defines how the experiment can choose the optimal outcome on completion.
      #
      # By default, Vanity will take the best alternative (highest conversion
      # rate) and use that as the outcome. You experiment may have different
      # needs, maybe you want the least performing alternative, or factor cost
      # in the equation?
      #
      # The default implementation reads like this:
      #   outcome_is do
      #     a, b = alternatives
      #     # a is expensive, only choose a if it performs 2x better than b
      #     a.measure > b.measure * 2 ? a : b
      #   end
      def outcome_is(&block)
        raise ArgumentError, "Missing block" unless block
        raise "outcome_is already called on this experiment" if @outcome_is
        @outcome_is = block
      end

      def complete!(outcome = nil)
        # This statement is equivalent to: return unless collecting?
        unless outcome
          if @outcome_is
            begin
              result = @outcome_is.call
              outcome = result.id if Alternative === result && result.experiment == experiment
            rescue
              Vanity.logger.warn "Error in Version#complete!: #{$!}"
            end
          else
            best = score.best
            outcome = best.id if best
          end
        end

        outcome
      end

      # -- Store/validate --

      # Get rid of all experiment data.
      def destroy
        connection.destroy_experiment @id
        @created_at = @completed_at = nil
      end

      # Called by experiment when saving experiment definition.
      def save
        true_false unless @alternatives
        fail "Experiment #{name} needs at least two alternatives" unless @alternatives.size >= 2
        if !@is_default_set
          default(@alternatives.first)
          Vanity.logger.warn("No default alternative specified; choosing #{@default} as default.")
        elsif alternative(@default).nil?
          #Specified a default that wasn't listed as an alternative; warn and override.
          Vanity.logger.warn("Attempted to set unknown alternative #{@default} as default! Using #{@alternatives.first} instead.")
          #Set the instance variable directly since default(value) is no longer defined
          @default = @alternatives.first
        end
      end

      # -- Default --

      # Call this method once to set a default alternative. Call without 
      # arguments to obtain the current default. If default is not specified,
      # the first alternative is used.
      #
      # @example Set the default alternative
      #   ab_test "Background color" do
      #     alternatives "red", "blue", "orange"
      #     default "red"
      #   end
      # @example Get the default alternative
      #   assert experiment(:background_color).default == "red"
      #
      def default(value)
        @default = value
        @is_default_set = true
        class << self
          define_method :default do |*args|
            raise ArgumentError, "default has already been set to #{@default.inspect}" unless args.empty?
            alternative(@default)
          end
        end
        nil
      end

      # -- Enabled --
      
      # Returns true if experiment is enabled, false if disabled.
      def enabled?
        !playground.collecting? || ( active? && connection.is_experiment_enabled?(@id) )
      end

      # Enable or disable the experiment. Only works if the playground is collecting
      # and this experiment is enabled.
      #
      # **Note** You should *not* set the enabled/disabled status of an
      # experiment until it exists in the database. Ensure that your experiment
      # has had #save invoked previous to any enabled= calls.
      def enabled=(bool)
        return unless playground.collecting? && active?
        if created_at.nil?
          warn 'DB has no created_at for this experiment version! This most likely means' + 
               'you didn\'t call #save before calling enabled=, which you should.'
        else
          connection.set_experiment_enabled(@id, bool)
        end
      end

      # -- Alternatives --

      # Call this method once to set alternative values for this experiment
      # (requires at least two values). Call without arguments to obtain
      # current list of alternatives. Call with a hash to set custom
      # probabilities.  If providing a hash of alternates, you may need to
      # specify a default unless your hashes are ordered. (Ruby >= 1.9)
      #
      # @example Define A/B test with three alternatives
      #   ab_test "Background color" do
      #     metrics :coolness
      #     alternatives "red", "blue", "orange"
      #   end
      #
      # @example Define A/B test with custom probabilities
      #   ab_test "Background color" do
      #     metrics :coolness
      #     alternatives "red" => 10, "blue" => 5, "orange => 1
      #     default "red"
      #   end
      #
      # @example Find out which alternatives this test uses
      #   alts = experiment(:background_color).alternatives
      #   puts "#{alts.count} alternatives, with the colors: #{alts.map(&:value).join(", ")}"
      def alternatives(*args)
        if has_alternative_weights?(args)
          build_alternatives_with_weights(args)
        else
          build_alternatives(args)
        end
      end

      # Returns an Alternative with the specified value.
      #
      # @example
      #   alternative(:red) == alternatives[0]
      #   alternative(:blue) == alternatives[2]
      def alternative(value)
        alternatives.find { |alt| alt.value == value }
      end

      # Defines an A/B test with two alternatives: false and true. This is the
      # default pair of alternatives, so just syntactic sugar for those who love
      # being explicit.
      #
      # @example
      #   ab_test "More bacon" do
      #     metrics :yummyness
      #     false_true
      #   end
      #
      def false_true
        alternatives false, true
      end
      alias true_false false_true

      # -- Unequal probability assignments --

      def set_alternative_probabilities(alternative_probabilities)
        # create @use_probabilities as a function to go from [0,1] to outcome
        cumulative_probability = 0.0
        new_probabilities = alternative_probabilities.map {|am| [am, (cumulative_probability += am.probability)/100.0]}
        @use_probabilities = new_probabilities
      end

      def use_alternative_probabilities?
        !!@use_probabilities
      end

      def random_alternative
        random_outcome = rand()
        @use_probabilities.each do |alternative, max_prob|
          return alternative.id if random_outcome < max_prob
        end
      end

      # Chooses an alternative for the identity and returns its index. This
      # method always returns the same alternative for a given experiment and
      # identity, and randomly distributed alternatives for each identity (in the
      # same experiment).
      def alternative_for(identity)
        if use_alternative_probabilities?
          existing_assignment = connection.ab_assigned id, identity
          return existing_assignment if existing_assignment
          return random_alternative
        end

        Digest::MD5.hexdigest("#{name}/#{identity}").to_i(17) % @alternatives.size
      end

      # Shortcut for Vanity.playground.connection
      def connection
        playground.connection
      end

      def playground
        @experiment.playground
      end

      def index(value)
        @alternatives.index(value)
      end

      def [](index)
        alternatives[index.to_i]
      end

      # True if this alternative is currently showing (see #chooses).
      def showing?(alternative)
        identity = experiment.identity()
        (connection.ab_showing(id, identity) || alternative_for(identity)) == alternative.id
      end

      # -- Reporting --

      def calculate_score
        if respond_to?(experiment.score_method)
          self.send(experiment.score_method)
        else
          score
        end
      end

      # Scores alternatives based on the current tracking data. This method
      # returns a structure with the following attributes:
      # [:alts]   Ordered list of alternatives, populated with scoring info.
      # [:base]   Second best performing alternative.
      # [:least]  Least performing alternative (but more than zero conversion).
      # [:choice] Choice alternative, either the outcome or best alternative.
      #
      # Alternatives returned by this method are populated with the following
      # attributes:
      # [:z_score]      Z-score (relative to the base alternative).
      # [:probability]  Probability (z-score mapped to 0, 90, 95, 99 or 99.9%).
      # [:difference]   Difference from the least performant altenative.
      #
      # The choice alternative is set only if its probability is higher or
      # equal to the specified probability (default is 90%).
      def score(probability = AbTest::DEFAULT_PROBABILITY)
        alts = alternatives
        # sort by conversion rate to find second best and 2nd best
        sorted = alts.sort_by(&:measure)
        base = sorted[-2]
        # calculate z-score
        pc = base.measure
        nc = base.participants
        alts.each do |alt|
          p = alt.measure
          n = alt.participants
          alt.z_score = (p - pc) / ((p * (1-p)/n) + (pc * (1-pc)/nc)).abs ** 0.5
          alt.probability = AbTest.probability(alt.z_score)
        end
        # difference is measured from least performant
        if least = sorted.find { |alt| alt.measure > 0 }
          alts.each do |alt|
            if alt.measure > least.measure
              alt.difference = (alt.measure - least.measure) / least.measure * 100
            end
          end
        end
        # best alternative is one with highest conversion rate (best shot).
        # choice alternative can only pick best if we have high probability (>90%).
        best = sorted.last if sorted.last.measure > 0.0
        choice = outcome ? alts[outcome.id] : (best && best.probability >= probability ? best : nil)
        Struct.new(:alts, :best, :base, :least, :choice, :method).new(alts, best, base, least, choice, :score)
      end

      # Scores alternatives based on the current tracking data, using Bayesian
      # estimates of the best binomial bandit. Based on the R bandit package,
      # http://cran.r-project.org/web/packages/bandit, which is based on
      # Steven L. Scott, A modern Bayesian look at the multi-armed bandit,
      # Appl. Stochastic Models Bus. Ind. 2010; 26:639-658.
      # (http://www.economics.uci.edu/~ivan/asmb.874.pdf)
      #
      # This method returns a structure with the following attributes:
      # [:alts]   Ordered list of alternatives, populated with scoring info.
      # [:base]   Second best performing alternative.
      # [:least]  Least performing alternative (but more than zero conversion).
      # [:choice] Choice alternative, either the outcome or best alternative.
      #
      # Alternatives returned by this method are populated with the following
      # attributes:
      # [:probability]  Probability (probability this is the best alternative).
      # [:difference]   Difference from the least performant altenative.
      #
      # The choice alternative is set only if its probability is higher or
      # equal to the specified probability (default is 90%).
      def bayes_bandit_score(probability = AbTest::DEFAULT_PROBABILITY)
        begin
          require "backports/1.9.1/kernel/define_singleton_method" if RUBY_VERSION < "1.9"
          require "integration"
          require "rubystats"
        rescue LoadError
          fail("to use bayes_bandit_score, install integration and rubystats gems")
        end

        begin
          require "gsl"
        rescue LoadError
          Vanity.logger.warn("for better integration performance, install gsl gem")
        end

        BayesianBanditScore.new(alternatives, outcome).calculate!
      end

      # Use the result of #score or #bayes_bandit_score to derive a conclusion. Returns an
      # array of claims.
      def conclusion(score = score())
        claims = []
        participants = score.alts.inject(0) { |t,alt| t + alt.participants }
        claims << if participants.zero?
          I18n.t('vanity.no_participants')
        else
          I18n.t('vanity.experiment_participants', :count=>participants)
        end
        # only interested in sorted alternatives with conversion
        sorted = score.alts.select { |alt| alt.measure > 0.0 }.sort_by(&:measure).reverse
        if sorted.size > 1
          # start with alternatives that have conversion, from best to worst,
          # then alternatives with no conversion.
          sorted |= score.alts
          # we want a result that's clearly better than 2nd best.
          best, second = sorted[0], sorted[1]
          if best.measure > second.measure
            diff = ((best.measure - second.measure) / second.measure * 100).round
            better = I18n.t('vanity.better_alternative_than', :probability=>diff.to_i, :alternative=> second.name) if diff > 0
            claims << I18n.t('vanity.best_alternative_measure', :best_alternative=>best.name, :measure=>'%.1f' % (best.measure * 100), :better_than=>better)
            if score.method == :bayes_bandit_score
              if best.probability >= 90
                claims << I18n.t('vanity.best_alternative_probability', :probability=>score.best.probability.to_i)
              else
                claims << I18n.t('vanity.low_result_confidence')
              end
            else
              if best.probability >= 90
                claims << I18n.t('vanity.best_alternative_is_significant', :probability=>score.best.probability.to_i)
              else
                claims << I18n.t('vanity.result_isnt_significant')
              end
            end
            sorted.delete best
          end
          sorted.each do |alt|
            if alt.measure > 0.0
              claims << I18n.t('vanity.converted_percentage', :alternative=>alt.name.sub(/^\w/, &:upcase), :percentage=>'%.1f' % (alt.measure * 100))
            else
              claims << I18n.t('vanity.didnt_convert', :alternative=>alt.name.sub(/^\w/, &:upcase))
            end
          end
        else
          claims << I18n.t('vanity.no_clear_winner')
        end
        claims << I18n.t('vanity.selected_as_best', :alternative=>score.choice.name.sub(/^\w/, &:upcase)) if score.choice
        claims
      end

      protected

      def has_alternative_weights?(args)
        @alternatives.nil? && args.size == 1 && args[0].is_a?(Hash)
      end
      
      def build_alternatives_with_weights(args)
        @alternatives = args[0]
        sum_of_probability = @alternatives.values.reduce(0) { |a,b| a+b }
        cumulative_probability = 0.0
        @use_probabilities = []
        result = []
        @alternatives = @alternatives.each_with_index.map do |(value, probability), i|
          result << alternative = Alternative.new( self, i, value )
          probability = probability.to_f / sum_of_probability
          @use_probabilities << [ alternative, cumulative_probability += probability ]
          value
        end

        result
      end

      def build_alternatives(args)
        @alternatives ||= args.empty? ? [true, false] : args.clone
        @alternatives.each_with_index.map do |value, i|
          Alternative.new(self, i, value)
        end
      end
    end

    class DefaultVersion < Version
      def initialize( experiment )
        super( experiment, nil )
      end
    end
  end
end
