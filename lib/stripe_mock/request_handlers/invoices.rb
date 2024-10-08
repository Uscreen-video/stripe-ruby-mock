module StripeMock
  module RequestHandlers
    module Invoices

      def Invoices.included(klass)
        klass.add_handler 'post /v1/invoices',               :new_invoice
        klass.add_handler 'get /v1/invoices/upcoming',       :upcoming_invoice
        klass.add_handler 'get /v1/invoices/(.*)/lines',     :get_invoice_line_items
        klass.add_handler 'get /v1/invoices/((?!search).*)', :get_invoice
        klass.add_handler 'get /v1/invoices/search',         :search_invoices
        klass.add_handler 'get /v1/invoices',                :list_invoices
        klass.add_handler 'post /v1/invoices/([^\/]*)',          :update_invoice
        klass.add_handler 'post /v1/invoices/([^\/]*)/pay',      :pay_invoice
        klass.add_handler 'post /v1/invoices/([^\/]*)/add_lines', :add_lines
        klass.add_handler 'post /v1/invoices/([^\/]*)/finalize', :finalize_invoice
      end

      def new_invoice(route, method_url, params, headers)
        id = new_id('in')
        invoice_item = Data.mock_line_item()
        invoices[id] = Data.mock_invoice([invoice_item], params.merge(:id => id))

        return_invoice(invoices[id], params)
      end

      def update_invoice(route, method_url, params, headers)
        route =~ method_url
        params.delete(:lines) if params[:lines]
        assert_existence :invoice, $1, invoices[$1]
        invoices[$1].merge!(params)

        return_invoice(invoices[$1], params)
      end

      SEARCH_FIELDS = ["currency", "customer", "number", "receipt_number", "subscription", "total"].freeze
      def search_invoices(route, method_url, params, headers)
        require_param(:query) unless params[:query]

        results = search_results(invoices.values, params[:query], fields: SEARCH_FIELDS, resource_name: "invoices")
        Data.mock_list_object(results, params)
      end

      def list_invoices(route, method_url, params, headers)
        params[:offset] ||= 0
        params[:limit] ||= 10

        result = invoices.clone

        if params[:customer]
          result.delete_if { |k,v| v[:customer] != params[:customer] }
        end

        Data.mock_list_object(result.values, params)
      end

      def get_invoice(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]

        return_invoice(invoices[$1], params)
      end

      def add_lines(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]

        raise Stripe::InvalidRequestError.new('Invoice is not a draft', nil, http_status: 400) unless invoices[$1][:status] == 'draft'

        params[:lines].each do |line|
          line_item = Data.mock_line_item(line)
          invoices[$1][:lines][:data] << line_item
        end

        return_invoice(invoices[$1], params)
      end

      def finalize_invoice(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]

        invoice = invoices[$1]
        raise Stripe::InvalidRequestError.new('Invoice is not a draft', nil, http_status: 400) unless invoice[:status] == 'draft'

        invoice[:status] = 'open'

        # Attach payment intent to the invoice
        payment_intent = new_payment_intent(nil, nil, {
          amount: invoice[:amount_due],
          currency: invoice[:currency],
          customer: invoice[:customer]
        }, nil)[:id]
        invoice[:payment_intent] = payment_intent

        return_invoice(invoice, params)
      end

      def get_invoice_line_items(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]
        invoices[$1][:lines]
      end

      def pay_invoice(route, method_url, params, headers)
        route =~ method_url
        assert_existence :invoice, $1, invoices[$1]
        charge = invoice_charge(invoices[$1])
        invoices[$1].merge!(
          :paid => true,
          :status => "paid",
          :attempted => true,
          :charge => charge[:id],
        )

        recurring_items = invoices[$1][:lines][:data].select { |item| item[:price] && present?(get_price(nil, nil, { price: item[:price] }, nil)[:recurring]) }
        if recurring_items.any?
          invoices[$1][:subscription] = create_subscription(nil, nil, { customer: invoices[$1][:customer], items: recurring_items.map { |item| { price: item[:price], quantity: item[:quantity] } } }, {})[:id]
        end

        return_invoice(invoices[$1], params)
      end

      def upcoming_invoice(route, method_url, params, headers = {})
        stripe_account = headers && headers[:stripe_account] || Stripe.api_key
        route =~ method_url
        raise Stripe::InvalidRequestError.new('Missing required param: customer if subscription is not provided', nil, http_status: 400) if params[:customer].nil? && params[:subscription].nil?
        raise Stripe::InvalidRequestError.new('When previewing changes to a subscription, you must specify either `subscription` or `subscription_items`', nil, http_status: 400) if !params[:subscription_proration_date].nil? && params[:subscription].nil? && params[:subscription_plan].nil?
        raise Stripe::InvalidRequestError.new('Cannot specify proration date without specifying a subscription', nil, http_status: 400) if !params[:subscription_proration_date].nil? && params[:subscription].nil?

        customer = customers[stripe_account][params[:customer]]
        assert_existence :customer, params[:customer], customer

        raise Stripe::InvalidRequestError.new("No upcoming invoices for customer: #{customer[:id]}", nil, http_status: 404) if customer[:subscriptions][:data].length == 0

        subscription =
          if params[:subscription]
            customer[:subscriptions][:data].select{|s|s[:id] == params[:subscription]}.first
          else
            customer[:subscriptions][:data].min_by { |sub| sub[:current_period_end] }
          end

        if params[:subscription_proration_date] && !((subscription[:current_period_start]..subscription[:current_period_end]) === params[:subscription_proration_date])
          raise Stripe::InvalidRequestError.new('Cannot specify proration date outside of current subscription period', nil, http_status: 400)
        end

        prorating = false
        subscription_proration_date = nil
        subscription_plan_id = params[:subscription_plan] || subscription[:plan][:id]
        subscription_quantity = params[:subscription_quantity] || subscription[:quantity]
        if subscription_plan_id != subscription[:plan][:id] || subscription_quantity != subscription[:quantity]
          prorating = true
          invoice_date = Time.now.to_i
          subscription_plan = assert_existence :plan, subscription_plan_id, plans[subscription_plan_id.to_s]
          preview_subscription = Data.mock_subscription
          preview_subscription = resolve_subscription_changes(preview_subscription, [subscription_plan], customer, { trial_end: params[:subscription_trial_end] })
          preview_subscription[:id] = subscription[:id]
          preview_subscription[:quantity] = subscription_quantity
          subscription_proration_date = params[:subscription_proration_date] || Time.now
        else
          preview_subscription = subscription
          invoice_date = subscription[:current_period_end]
        end

        invoice_lines = []

        if prorating
          unused_amount = (
            subscription[:plan][:amount].to_f *
              subscription[:quantity] *
              (subscription[:current_period_end] - subscription_proration_date.to_i) / (subscription[:current_period_end] - subscription[:current_period_start])
            ).ceil

          invoice_lines << Data.mock_line_item(
                                   id: new_id('ii'),
                                   amount: -unused_amount,
                                   description: 'Unused time',
                                   plan: subscription[:plan],
                                   period: {
                                       start: subscription_proration_date.to_i,
                                       end: subscription[:current_period_end]
                                   },
                                   quantity: subscription[:quantity],
                                   proration: true
          )

          preview_plan = assert_existence :plan, params[:subscription_plan], plans[params[:subscription_plan]]
          if preview_plan[:interval] == subscription[:plan][:interval] && preview_plan[:interval_count] == subscription[:plan][:interval_count] && params[:subscription_trial_end].nil?
            remaining_amount = preview_plan[:amount] * subscription_quantity * (subscription[:current_period_end] - subscription_proration_date.to_i) / (subscription[:current_period_end] - subscription[:current_period_start])
            invoice_lines << Data.mock_line_item(
                                     id: new_id('ii'),
                                     amount: remaining_amount,
                                     description: 'Remaining time',
                                     plan: preview_plan,
                                     period: {
                                         start: subscription_proration_date.to_i,
                                         end: subscription[:current_period_end]
                                     },
                                     quantity: subscription_quantity,
                                     proration: true
            )
          end
        end

        subscription_line = get_mock_subscription_line_item(preview_subscription)
        invoice_lines << subscription_line

        Data.mock_invoice(invoice_lines,
          id: new_id('in'),
          customer: customer[:id],
          discount: customer[:discount],
          created: invoice_date,
          starting_balance: customer[:account_balance],
          subscription: preview_subscription[:id],
          period_start: prorating ? invoice_date : preview_subscription[:current_period_start],
          period_end: prorating ? invoice_date : preview_subscription[:current_period_end],
          next_payment_attempt: preview_subscription[:current_period_end] + 3600 )
      end

      private

      def present?(obj)
        obj && obj != {} && obj != []
      end

      def return_invoice(invoice, params)
        inv = invoice.clone

        if present?(params[:expand])
          [params[:expand]].flatten.each do |field|
            case field
            when 'customer'
              inv[:customer] = get_customer(nil, nil, {customer: inv[:customer]}, nil) if present?(inv[:customer])
            when 'charge'
              inv[:charge] = get_charge(nil, nil, {charge: inv[:charge]}, nil) if present?(inv[:charge])
            when 'subscription'
              inv[:subscription] = retrieve_subscription(nil, nil, {subscription: inv[:subscription]}, nil) if present?(inv[:subscription])
            when 'payment_intent'
              inv[:payment_intent] = get_payment_intent(nil, nil, {payment_intent: inv[:payment_intent]}, nil) if present?(inv[:payment_intent])
            end
          end
        end

        inv
      end

      def get_mock_subscription_line_item(subscription)
        Data.mock_line_item(
          id: subscription[:id],
          type: "subscription",
          plan: subscription[:plan],
          amount: subscription[:status] == 'trialing' ? 0 : subscription[:plan][:amount] * subscription[:quantity],
          discountable: true,
          quantity: subscription[:quantity],
          period: {
            start: subscription[:current_period_end],
            end: get_ending_time(subscription[:current_period_start], subscription[:plan], 2)
          })
      end

      ## charge the customer on the invoice, if one does not exist, create
      #anonymous charge
      def invoice_charge(invoice)
        begin
          new_charge(nil, nil, {customer: invoice[:customer]["id"], amount: invoice[:amount_due], currency: StripeMock.default_currency}, nil)
        rescue Stripe::InvalidRequestError
          new_charge(nil, nil, {source: generate_card_token, amount: invoice[:amount_due], currency: StripeMock.default_currency}, nil)
        end
      end

    end
  end
end
