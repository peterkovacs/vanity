require "test_helper"

class BaselineTestController < ActionController::Base
  use_vanity :current_user
  attr_accessor :current_user

  def test_render
    Vanity.baseline_test(:simple)
    render text: "ok"
  end

  def test_view
    render :inline => "<% baseline_test(:simple) %>ok"
  end

  def track
    Vanity.baseline_test(:simple)
    Vanity.track!(:coolness) if params[:track]
    render text: ""
  end
end

class BaselineTestTest < ActionController::TestCase
  tests BaselineTestController

  def setup
    super
    metric "Coolness"
  end

  def test_definition
    new_baseline_test :two do
      metrics :coolness
    end
  end

  # -- Experiment Enabled/disabled --
  def test_new_test_is_disabled_when_experiments_start_enabled_is_false
    Vanity.configuration.experiments_start_enabled = false
    exp = new_baseline_test :test, enable: false do
      metrics :coolness
    end
    assert !exp.enabled?
  end

  def test_new_test_is_enabled_when_experiments_start_enabled_is_true
    Vanity.configuration.experiments_start_enabled = true
    exp = new_baseline_test :test, enable: false do
      metrics :coolness
    end
    assert exp.enabled?
  end

  def test_set_enabled_while_active
    Vanity.playground.collecting = true
    exp = new_baseline_test :test do
      metrics :coolness
    end

    exp.enabled = true
    assert exp.enabled?

    exp.enabled = false
    assert !exp.enabled?
  end

  def test_enabled_persists_across_definitions
    Vanity.configuration.experiments_start_enabled = false
    Vanity.playground.collecting = true
    new_baseline_test :test, :enable => false do
      metrics :coolness
    end
    assert !experiment(:test).enabled? #starts off false

    new_playground
    metric "Coolness"

    new_baseline_test :test, :enable => false do
      metrics :coolness
    end
    assert !experiment(:test).enabled? #still false
    experiment(:test).enabled = true
    assert experiment(:test).enabled? #now true

    new_playground
    metric "Coolness"

    new_baseline_test :test, :enable => false do
      metrics :coolness
    end
    assert experiment(:test).enabled? #still true
    experiment(:test).enabled = false
    assert !experiment(:test).enabled? #now false again
  end

  def test_enabled_persists_across_definitions_when_starting_enabled
    Vanity.configuration.experiments_start_enabled = true
    Vanity.playground.collecting = true
    new_baseline_test :test, :enable => false do
      metrics :coolness
    end
    assert experiment(:test).enabled? #starts off true

    new_playground
    metric "Coolness"

    new_baseline_test :test, :enable => false do
      metrics :coolness
    end
    assert experiment(:test).enabled? #still true
    experiment(:test).enabled = false
    assert !experiment(:test).enabled? #now false

    new_playground
    metric "Coolness"

    new_baseline_test :test, :enable => false do
      metrics :coolness
    end
    assert !experiment(:test).enabled? #still false
    experiment(:test).enabled = true
    assert experiment(:test).enabled? #now true again
  end

  # -- Experiment metric --

  def test_explicit_metric
    new_baseline_test :abcd do
      metrics :coolness
    end
    assert_equal [Vanity.playground.metric(:coolness)], experiment(:abcd).metrics
  end

  def test_implicit_metric
    new_baseline_test :abcd do
    end
    assert_equal [Vanity.playground.metric(:abcd)], experiment(:abcd).metrics
  end

  def test_metric_tracking_into_alternative
    metric "Coolness"
    new_baseline_test :abcd do
      metrics :coolness
    end
    experiment(:abcd).choose
    Vanity.playground.track! :coolness
    assert_equal 1, experiment(:abcd).conversions
  end

  # -- track! --

  def test_track_with_identity_overrides_default
    identities = ["quux"]
    new_baseline_test :foobar do
      identify { identities.pop || "6e98ec" }
    end
    2.times { experiment(:foobar).choose }
    assert_equal 0, experiment(:foobar).conversions
    experiment(:foobar).track!(:coolness, Time.now, 1)
    assert_equal 1, experiment(:foobar).conversions
    experiment(:foobar).track!(:coolness, Time.now, 1, :identity=>"quux")
    assert_equal 2, experiment(:foobar).conversions
  end

  def test_destroy_experiment
    new_baseline_test :simple do
      identify { "me" }
      metrics :coolness
    end
    experiment(:simple).choose
    metric(:coolness).track!
    assert experiment(:simple).active?

    experiment(:simple).destroy
    assert experiment(:simple).active?
    assert_equal 0, experiment(:simple).alternative.participants
    assert_equal 0, experiment(:simple).alternative.conversions
    assert_equal 0, experiment(:simple).alternative.converted
  end

  # -- A/B helper methods --

  def test_fail_if_no_experiment
    assert_raise Vanity::NoExperimentError do
      get :test_render
    end
  end

  def test_ab_test_chooses_in_render
    new_baseline_test :simple do
      metrics :coolness
    end

    responses = Array.new(100) do
      @controller = nil ; setup_controller_request_and_response
      get :test_render
      @response.body
    end
    assert_equal %w{ok}, responses.uniq.sort
    assert_equal 100, experiment(:simple).alternative.participants
    assert_equal 0, experiment(:simple).alternative.converted
    assert_equal 0, experiment(:simple).alternative.conversions
  end

  def test_ab_test_chooses_view_helper
    new_baseline_test :simple do
      metrics :coolness
    end
    responses = Array.new(100) do
      @controller = nil ; setup_controller_request_and_response
      get :test_view
      @response.body
    end
    assert_equal %w{ok}, responses.uniq.sort
    assert_equal 100, experiment(:simple).alternative.participants
    assert_equal 0, experiment(:simple).alternative.converted
    assert_equal 0, experiment(:simple).alternative.conversions
  end

  def test_ab_test_track
    new_baseline_test :simple do
      metrics :coolness
    end
    responses = Array.new(100) do |i|
      @controller = nil ; setup_controller_request_and_response
      get :track, track: i % 2 == 0
      @response.body
    end

    assert_equal 100, experiment(:simple).alternative.participants
    assert_equal 50, experiment(:simple).alternative.converted
    assert_equal 50, experiment(:simple).alternative.conversions
  end
end
