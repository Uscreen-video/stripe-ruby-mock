module StripeMock
  module RequestHandlers
    module Helpers
      # API version where discounts parameter replaces coupon/promotion_code
      BASIL_API_VERSION = '2025-03-31.basil'

      def api_version_supports_discounts?(headers)
        return false unless headers
        api_version = headers[:stripe_version] || headers['stripe-version']
        return false unless api_version

        # Compare API versions - handle both date format (2025-03-31) and date.suffix format (2025-03-31.basil)
        version_date = api_version.split('.').first
        basil_date = BASIL_API_VERSION.split('.').first

        # Compare dates (YYYY-MM-DD format)
        version_date >= basil_date
      end

      def add_coupon_to_object(object, coupon)
        discount_attrs = {}.tap do |attrs|
          attrs[:object]                = "discount"
          attrs[object[:object]]         = object[:id]
          attrs[:coupon]                 = coupon
          attrs[:start]                  = Time.now.to_i
          attrs[:end]                    = (DateTime.now >> coupon[:duration_in_months].to_i).to_time.to_i if coupon[:duration] == 'repeating'
          attrs[:id]                     = new_id("di")
        end

        object[:discount] = Stripe::Discount.construct_from(discount_attrs)
        object
      end

      def delete_coupon_from_object(object)
        object[:discount] = nil
        object
      end

      def process_discounts_parameter(params, headers, object)
        discounts = params[:discounts]
        return unless discounts

        unless discounts.is_a?(Array)
          raise Stripe::InvalidRequestError.new("discounts must be an array", 'discounts', http_status: 400)
        end

        object[:discounts] = []

        discounts.each do |discount_param|
          unless discount_param.is_a?(Hash)
            raise Stripe::InvalidRequestError.new("Each discount must be an object", 'discounts', http_status: 400)
          end

          if discount_param[:coupon] && discount_param[:promotion_code]
            raise Stripe::InvalidRequestError.new("You may only specify one of these parameters: coupon, promotion_code", 'discounts', http_status: 400)
          end

          discount_attrs = {}
          discount_attrs[:object] = "discount"
          discount_attrs[object[:object]] = object[:id]
          discount_attrs[:start] = Time.now.to_i
          discount_attrs[:id] = new_id("di")

          if discount_param[:coupon]
            coupon_id = discount_param[:coupon]
            coupon = coupons[coupon_id]
            unless coupon
              raise Stripe::InvalidRequestError.new("No such coupon: #{coupon_id}", 'discounts', http_status: 400)
            end
            discount_attrs[:coupon] = coupon
            discount_attrs[:end] = (DateTime.now >> coupon[:duration_in_months].to_i).to_time.to_i if coupon[:duration] == 'repeating'
          elsif discount_param[:promotion_code]
            promotion_code_id = discount_param[:promotion_code]
            promotion_code = promotion_codes[promotion_code_id]
            unless promotion_code
              raise Stripe::InvalidRequestError.new("No such promotion code: #{promotion_code_id}", 'discounts', http_status: 400)
            end
            # Promotion codes reference coupons - resolve coupon from promotion code
            coupon_ref = promotion_code[:coupon]
            # coupon_ref might be an ID string or a coupon object
            coupon = coupon_ref.is_a?(String) ? coupons[coupon_ref] : coupon_ref
            unless coupon
              raise Stripe::InvalidRequestError.new("No such coupon: #{coupon_ref}", 'discounts', http_status: 400)
            end
            discount_attrs[:coupon] = coupon
            discount_attrs[:end] = (DateTime.now >> coupon[:duration_in_months].to_i).to_time.to_i if coupon[:duration] == 'repeating'
          else
            raise Stripe::InvalidRequestError.new("Each discount must specify either coupon or promotion_code", 'discounts', http_status: 400)
          end

          object[:discounts] << Stripe::Discount.construct_from(discount_attrs)
        end

        object
      end
    end
  end
end
