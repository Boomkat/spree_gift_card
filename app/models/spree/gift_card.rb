require 'spree/core/validators/email'

module Spree
  class GiftCard < ActiveRecord::Base

    UNACTIVATABLE_ORDER_STATES = ["complete", "awaiting_return", "returned"]

    belongs_to :variant
    belongs_to :line_item

    has_many :transactions, class_name: 'Spree::GiftCardTransaction'

    validates :code,               presence: true, uniqueness: true
    validates :current_value,      presence: true
    validates :email, email: true, presence: true
    validates :name,               presence: true
    validates :original_value,     presence: true

    before_validation :generate_code, on: :create
    before_validation :set_calculator, on: :create
    before_validation :set_values, on: :create

    scope :ready_for_release, lambda { where(ready_for_release: true) }
    # note send_at and sent_at
    scope :due_for_delivery, lambda { ready_for_release.where(sent_at: nil).where("send_at < ?", Time.zone.now) }

    include Spree::CalculatedAdjustments

    def apply(order)
      # Nothing to do if the gift card is already associated with the order
      return if order.gift_credit_exists?(self)
      order.update!
      Spree::Adjustment.create!(
            amount: compute_amount(order),
            order: order,
            adjustable: order,
            source: self,
            mandatory: true,
            label: "#{Spree.t(:gift_card)}"
          )

      order.update!
    end

    def release!(order)
      update_attribute(:ready_for_release, true)

      deliver!(order) unless queued_for_later?
    end

    def deliver!(order)
      raise "Not ready for delivery -- has this card been paid for?" unless ready_for_release?

      Spree::OrderMailer.gift_card_email(id, order).deliver
      update_attribute(:sent_at, Time.zone.now)
    end

    def queued_for_later?
      send_method == "delayed"
    end

    # Calculate the amount to be used when creating an adjustment
    def compute_amount(calculable)
      self.calculator.compute(calculable, self)
    end

    def debit(amount, order)
      raise 'Cannot debit gift card by amount greater than current value.' if (self.current_value - amount.to_f.abs) < 0
      transaction = self.transactions.build
      transaction.amount = amount
      transaction.order  = order
      self.current_value = self.current_value - amount.abs
      self.save
    end

    def price
      self.line_item ? self.line_item.price * self.line_item.quantity : self.variant.price
    end

    def order_activatable?(order)
      order &&
      current_value > 0 &&
      !UNACTIVATABLE_ORDER_STATES.include?(order.state)
    end

    private

    def generate_code
      until self.code.present? && self.class.where(code: self.code).count == 0
        self.code = Digest::SHA1.hexdigest([Time.now, rand].join)
      end
    end

    def set_calculator
      self.calculator = Spree::Calculator::GiftCard.new
    end

    def set_values
      self.current_value  = self.variant.try(:price)
      self.original_value = self.variant.try(:price)
    end

  end
end
