# encoding: UTF-8
# frozen_string_literal: true

class BlockchainService

  def initialize(blockchain)
    @blockchain = blockchain
    @client     = BlockAPI[blockchain.key]
  end

  def current_height
    @blockchain.height
  end
  
  def process_blockchain
    current_block   = @blockchain.height || 0
    latest_block    = @client.latest_block_number

    (current_block..latest_block).each do |block_id|
      block_json = @client.get_block(block_id)

      next if block_json.blank?
      transactions = block_json.fetch('transactions')
      deposits = build_deposits(transactions, block_json, latest_block)

      save_deposits!(deposits)

      # Mark block as processed if both deposits and withdrawals were confirmed.
      @blockchain.update(height: block_id) if latest_block - block_id > @blockchain.confirmations_max
      # TODO: exceptions processing.
    end
  end

  private

  def build_deposits(transactions, block_json, latest_block)
    transactions.each_with_object([]) do |tx, deposits|
      next if @client.invalid_transaction?(tx)

      payment_addresses_where(address: @client.to_address(tx)) do |payment_address|
        # TODO: Add comment.
        next if payment_address.currency.code.eth? != @client.is_eth_tx?(tx)

        deposit_txs = @client.build_deposit(tx, block_json, latest_block, payment_address.currency)
        deposit_txs.fetch(:entries).each_with_index do |entry, i|
          deposits << { txid:           deposit_txs[:id],
                        address:        entry[:address],
                        amount:         entry[:amount],
                        member:         payment_address.account.member,
                        currency:       payment_address.currency,
                        txout:          i,
                        confirmations:  deposit_txs[:confirmations] }
        end
      end
    end
  end

  def save_deposits!(deposits)
    deposits.each do |deposit_hash|

      # If deposit doesn't exist create it.
      deposit = Deposits::Coin.find_or_create_by!(deposit_hash.except(:confirmations))

      # Otherwise update confirmations amount for existing deposit.
      if deposit.confirmations != deposit_hash.fetch(:confirmations)
        deposit.update(confirmations: deposit_hash.fetch(:confirmations))
      end

      # Accept deposit if it received minimum confirmations for current blockchain.
      if @blockchain.deposit_confirmations > 0 && deposit.confirmations >= @blockchain.deposit_confirmations
        deposit.accept!
      end
    end
  end

  def payment_addresses_where(options)
    options = { currency_id: @blockchain.currencies.pluck(:id) }.merge(options)
    PaymentAddress
      .where(options)
      .each do |payment_address|
        yield payment_address
      end
  end

  # TODO: check if Deposit doesn't exist.
  # example deposit_coin.rb
  # def deposit_entry_processable?(currency, tx, entry, index)
  #   PaymentAddress.where(currency: currency, address: entry[:address]).exists? &&
  #       !Deposit.where(currency: currency, txid: tx[:id], txout: index).exists?
  # end
  #
end
