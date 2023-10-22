// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// SUI DUTCH AUCTION implementation. Supports dutchAuction of any assets
///
/// Makes use of `sui::dynamic_object_field` module by attaching `DutchAuction`
/// objects as fields to the `Sda` object; as well as stores and
/// merges user profits as dynamic object fields (ofield).
///
/// illustration of the dynamic field architecture for dutchAuctions:
/// ```
///             /--->DutchAuction--->Item
/// (Sda)--->DutchAuction--->Item
///             \--->DutchAuction--->Item
/// ```
///
module nfts::sda {
    use sui::dynamic_object_field as ofield;
    use sui::tx_context::{Self, TxContext};
    use sui::object::{Self, ID, UID};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::sui::SUI;


    /// Error code when the auction is expired.
    const EAuctionExpired: u64 = 0;

    /// Error code when amount paid is too low.
    const EAmountTooLow: u64 = 1;

    /// Error code when someone tries to delist without ownership.
    const ENotOwner: u64 = 2;

    /// A shared `Sda`. Can be created by anyone using the
    /// `create` function.
    struct Sda has key {
        id: UID,
        feesPercentage : u64,
        proceeds_recipient: address
    }

    /// A single dutchAuction which contains the listed item
    struct DutchAuction has key, store {
        id: UID,
        /// Owner of the item to be sold.
        seller: address,

        /// The four next fields are used to compute the expected price at any given time.
        timestamp_start: u64,
        timestamp_end: u64,
        price_start: u64,
        price_end: u64
    }

    /// Create a new shared Sda.
    public entry fun create(feesPercentage : u64, ctx: &mut TxContext) {
        let id = object::new(ctx);
        transfer::share_object(
            Sda {
                id,
                feesPercentage,
                proceeds_recipient: tx_context::sender(ctx)
            }
        )
    }

    /// List an item at the Sda.
    public entry fun createDutchAuction<T: key + store>(
        sda: &mut Sda,
        item: T,
        timestamp_start: u64,
        timestamp_end: u64,
        price_start: u64,
        price_end: u64,
        ctx: &mut TxContext,
    ) {
        let item_id = object::id(&item);
        let dutchAuction = DutchAuction {
            id: object::new(ctx),
            seller: tx_context::sender(ctx),
            timestamp_start,
            timestamp_end,
            price_start,
            price_end
        };

        ofield::add(&mut dutchAuction.id, true, item);
        ofield::add(&mut sda.id, item_id, dutchAuction)
    }

    /// Purchase an item using a known DutchAuction. Payment is done in Coin<C>.
    /// Amount paid must match the requested amount. If conditions are met,
    /// owner of the item gets the payment and buyer receives their item.
    public fun buy<T: key + store>(
        sda: &mut Sda,
        item_id: ID,
        paid: Coin<SUI>,
        ctx: &mut TxContext
    ): T {

        let feesPercentage = sda.feesPercentage;
        let proceeds_recipient = sda.proceeds_recipient;

        let DutchAuction {
            id,
            seller,
            timestamp_start,
            timestamp_end,
            price_start,
            price_end
        } = ofield::remove(&mut sda.id, item_id);

        let timestamp_now = tx_context::epoch_timestamp_ms(ctx);

        assert!(timestamp_now <= timestamp_end && timestamp_now >= timestamp_start, EAuctionExpired);

        let expected_price = price_end + ((timestamp_end - timestamp_now) / (timestamp_end - timestamp_start)) * (price_start - price_end);

        assert!(expected_price <= coin::value(&paid), EAmountTooLow);

        /// Split the 'paid' coin into two new coins
        let proceeds = coin::split(&mut paid, (coin::value(&paid) * feesPercentage) / 100,  ctx);

        /// Check if there's already some proceeds for the reseller.
        /*if (ofield::exists_<address>(&sda.id, seller)) {
            coin::join(
                ofield::borrow_mut<address, Coin<SUI>>(&mut sda.id, seller),
                paid
            )
        } else {*/
        // Otherwise attach `paid` to the `Sda` under owner's `address`.
        ofield::add(&mut sda.id, seller, paid);
        //};
        
       
        /*if (ofield::exists_<address>(&sda.id, proceeds_recipient)) {
            coin::join(
                ofield::borrow_mut<address, Coin<SUI>>(&mut sda.id, proceeds_recipient),
                proceeds
            )
        } else {*/
        ofield::add(&mut sda.id, proceeds_recipient, proceeds);
        //};

        let item = ofield::remove(&mut id, true);
        object::delete(id);
        item
    }

    /// Call [`buy`] and transfer item to the sender.
    public entry fun buy_and_receive<T: key + store>(
        sda: &mut Sda,
        item_id: ID,
        paid: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        transfer::public_transfer(
            buy<T>(sda, item_id, paid, ctx),
            tx_context::sender(ctx)
        )
    }

    /// Take profits from selling items on the `Sda`.
    public fun take_profits(
        sda: &mut Sda,
        ctx: &mut TxContext
    ): Coin<SUI> {
        ofield::remove<address, Coin<SUI>>(&mut sda.id, tx_context::sender(ctx))
    }

    /// Call [`take_profits`] and transfer Coin to the sender.
    public entry fun take_profits_and_receive(
        sda: &mut Sda,
        ctx: &mut TxContext
    ) {
        transfer::public_transfer(
            take_profits(sda, ctx),
            tx_context::sender(ctx)
        )
    }

    /// Remove dutchAuction and get an item back. Only owner can do that.
    public fun delist<T: key + store>(
        sda: &mut Sda,
        item_id: ID,
        ctx: &mut TxContext
    ): T {
        let DutchAuction {
            id,
            seller,
            timestamp_start: _,
            timestamp_end: _,
            price_start: _,
            price_end: _
        } = ofield::remove(&mut sda.id, item_id);

        assert!(tx_context::sender(ctx) == seller, ENotOwner);

        let item = ofield::remove(&mut id, true);
        object::delete(id);
        item
    }


    /// Call [`delist`] and transfer item to the sender.
    public entry fun delist_and_take<T: key + store>(
        sda: &mut Sda,
        item_id: ID,
        ctx: &mut TxContext
    ) {
        let item = delist<T>(sda, item_id, ctx);
        transfer::public_transfer(item, tx_context::sender(ctx));
    }
}
