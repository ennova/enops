require 'minitest/autorun'

class GemspecTest < Minitest::Test
  def setup
    @spec = Gem::Specification.load(File.expand_path('../enops.gemspec', __dir__))
    @requirement = @spec.runtime_dependencies
      .find { |dependency| dependency.name == 'activesupport' }
      .requirement
  end

  def test_supports_active_support_8_1
    assert @requirement.satisfied_by?(Gem::Version.new('8.1.0'))
  end

  def test_does_not_claim_support_for_active_support_8_2
    refute @requirement.satisfied_by?(Gem::Version.new('8.2.0'))
  end
end
