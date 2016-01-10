require "test_helper"

describe Vanity::Helpers do
  describe "#track!" do
    it "identity option sets identity" do
      metric "Coolness"
      new_ab_test :foobar do
        alternatives "foo", "bar"
        default "foo"
        metrics :coolness
      end

      # Force participation in the experiment.
      Vanity.context = stub( vanity_identity: 'quux' )
      experiment(:foobar).choose
      Vanity.context = nil

      Vanity.track!(:coolness, :identity=>'quux')

      assert_equal 1, experiment(:foobar).alternatives.sum(&:conversions)
    end

    it "accepts value for conversion" do
      metric "Coolness"
      new_ab_test :foobar do
        alternatives "foo", "bar"
        default "foo"
        metrics :coolness
      end

      # Force participation in the experiment.
      Vanity.context = stub( vanity_identity: 'quux' )
      experiment(:foobar).choose
      Vanity.context = nil

      Vanity.track!(:coolness, :identity=>'quux', :values=>[2])

      assert_equal 2, experiment(:foobar).alternatives.sum(&:conversions)
    end
  end
end
