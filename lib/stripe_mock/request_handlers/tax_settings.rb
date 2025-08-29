module StripeMock
  module RequestHandlers
    module Tax
      module Settings
        def Settings.included(klass)
          klass.add_handler 'get /v1/tax/settings', :get_tax_settings
        end

        def get_tax_settings(route, method_url, params, headers)
          Data.mock_tax_settings(params)
        end
      end
    end
  end
end
