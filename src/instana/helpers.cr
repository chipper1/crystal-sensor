module Instana
  module Helpers
    EUM_SNIPPET      = (File.read(File.dirname(__FILE__) + "/eum/eum.js.erb"))
    EUM_TEST_SNIPPET = (File.read(File.dirname(__FILE__) + "/eum/eum-test.js.erb"))

    # Returns a processed javascript snippet to be placed within the HEAD tag of an HTML page.
    #
    def self.eum_snippet(api_key, kvs = {Symbol, String})
      return nil if !::Instana.tracer.tracing?

      ::Instana.config.eum_api_key = api_key
      ::Instana.config.eum_baggage = kvs

      ERB.new(EUM_SNIPPET).result
    rescue e
      Instana.logger.error "eum_snippet:#{File.basename(__FILE__)}:#{__LINE__}: #{e.message}"
      Instana.logger.debug e.backtrace.join("\r\n")
      return nil
    end

    # Returns a processed javascript snippet to be placed within the HEAD tag of an HTML page.
    # This one is used for testing only
    #
    def self.eum_test_snippet(api_key, kvs = {Symbol, String})
      return nil if !::Instana.tracer.tracing?

      ::Instana.config.eum_api_key = api_key
      ::Instana.config.eum_baggage = kvs

      ERB.new(EUM_TEST_SNIPPET).result
    rescue e
      Instana.logger.error "eum_test_snippet:#{File.basename(__FILE__)}:#{__LINE__}: #{e.message}"
      Instana.logger.debug e.backtrace.join("\r\n")
      return nil
    end
  end
end
