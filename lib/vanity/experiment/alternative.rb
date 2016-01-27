module Vanity
  module Experiment

    # One of several alternatives in an A/B test (see AbTest#alternatives).
    class Alternative

      def initialize(version, id, value) #, participants, converted, conversions)
        @version = version
        @id = id
        @name = I18n.t('vanity.option_number', :char=>(@id + 65).chr.upcase)
        @value = value
      end

      # Alternative id, only unique for this version.
      attr_reader :id

      # Alternative name (option A, option B, etc).
      attr_reader :name

      # Alternative value.
      attr_reader :value

      # Version this alternative belongs to.
      attr_reader :version

      def experiment
        version.experiment
      end

      # Number of participants who viewed this alternative.
      def participants
        load_counts unless @participants
        @participants
      end

      # Number of participants who converted on this alternative (a
      # participant is counted only once).
      def converted
        load_counts unless @converted
        @converted
      end

      # Number of conversions for this alternative (same participant may be
      # counted more than once).
      def conversions
        load_counts unless @conversions
        @conversions
      end

      # Z-score for this alternative, related to 2nd-best performing
      # alternative. Populated by AbTest#score if #score_method is :z_score.
      attr_accessor :z_score

      # Probability alternative is best. Populated by AbTest#score.
      attr_accessor :probability

      # Difference from least performing alternative. Populated by
      # AbTest#score.
      attr_accessor :difference

      # Conversion rate calculated as converted/participants
      def conversion_rate
        @conversion_rate ||= (participants > 0 ? converted.to_f/participants.to_f  : 0.0)
      end

      # The measure we use to order (sort) alternatives and decide which one
      # is better (by calculating z-score). Defaults to conversion rate.
      def measure
        conversion_rate
      end

      def <=>(other)
        measure <=> other.measure
      end

      def ==(other)
        other && id == other.id && version == other.version
      end

      def to_s
        name
      end

      def inspect
        "#{name}: #{value} #{converted}/#{participants}"
      end

      def fingerprint
        Digest::MD5.hexdigest("#{version.id}:#{id}")[-10,10]
      end

      def load_counts
        if @version.playground.collecting?
          @participants, @converted, @conversions = @version.playground.connection.ab_counts(@version.id, id).values_at(:participants, :converted, :conversions)
        else
          @participants = @converted = @conversions = 0
        end
      end

      def default?
        @version.default == self
      end
    end
  end
end
