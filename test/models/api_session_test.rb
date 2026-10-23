require "test_helper"

class ApiSessionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "session@example.test", password: "test-password-123")
  end

  test "issues a thirty two byte hex token and persists only its SHA256 digest" do
    session = token = nil

    assert_difference "ApiSession.count", 1 do
      session, token = ApiSession.issue(@user)
    end

    assert_match(/\A[0-9a-f]{64}\z/, token)
    assert_equal 32, [ token ].pack("H*").bytesize
    assert session.persisted?
    assert_equal @user, session.user
    assert_equal Digest::SHA256.hexdigest(token), session.reload.token_digest
    assert_not_equal token, session.token_digest
    assert_not_includes session.attributes.values, token
    assert_equal session, ApiSession.authenticate(token)
    assert_nil ApiSession.authenticate("unknown-token")
    assert_nil ApiSession.authenticate(session.token_digest)
  end

  test "expires exactly eight hours after issuance" do
    freeze_time do
      session, token = ApiSession.issue(@user)

      assert_equal Time.current + 8.hours, session.reload.expires_at

      travel 8.hours - 1.second
      assert_equal session, ApiSession.authenticate(token)

      travel 1.second
      assert_nil ApiSession.authenticate(token)

      travel 1.second
      assert_nil ApiSession.authenticate(token)
      assert ApiSession.exists?(session.id)
    end
  end

  test "allows independent sessions for the same user without revoking earlier tokens" do
    freeze_time do
      first_session, first_token = ApiSession.issue(@user)
      travel 1.hour

      second_session = second_token = nil
      assert_difference "@user.api_sessions.count", 1 do
        second_session, second_token = ApiSession.issue(@user)
      end

      assert_not_equal first_token, second_token
      assert_not_equal first_session.token_digest, second_session.token_digest
      assert_equal first_session, ApiSession.authenticate(first_token)
      assert_equal second_session, ApiSession.authenticate(second_token)

      travel 7.hours

      assert_nil ApiSession.authenticate(first_token)
      assert_equal second_session, ApiSession.authenticate(second_token)
    end
  end
end
