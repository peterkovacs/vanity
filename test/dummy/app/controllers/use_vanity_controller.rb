class UseVanityController < ActionController::Base
  class TestModel
    def test_method
      Vanity.ab_test(:pie_or_cake)
    end
  end

  attr_accessor :current_user

  def index
    render :text=>Vanity.ab_test(:pie_or_cake)
  end

  def js
    Vanity.ab_test(:pie_or_cake)
    render :inline => "<%= vanity_js -%>"
  end

  def model_js
    TestModel.new.test_method
    render :inline => "<%= vanity_js -%>"
  end

  def replace_identity
    Vanity.ab_test(:pie_or_cake)
    vanity_replace_identity_with( 'new_identity' )

    render :inline => "<%= vanity_js -%>"
  end
end
