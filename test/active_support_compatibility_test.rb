require 'minitest/autorun'
require 'enops'
require 'active_support/inflector'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/object/deep_dup'

class ActiveSupportCompatibilityTest < Minitest::Test
  def test_active_support_extensions_used_by_enops
    assert_equal({ keep: true }, { keep: true, remove: true }.except(:remove))
    assert_equal({ nested: [] }, { nested: [] }.deep_dup)
    assert_nil ''.presence
    assert_equal 'child-account', 'Child Account'.parameterize
  end
end
