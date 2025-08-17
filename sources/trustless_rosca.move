module retamifi::trustless_rosca {
    use std::signer;
    use std::vector;
    use std::option::{Self};
    use std::string::{Self, String};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::event;
    use aptos_framework::object::{Self};

    use aptos_token_objects::collection;
    use aptos_token_objects::token;

    // === CONSTANTS ===
    
    /// User is not authorized to perform this action
    const E_NOT_AUTHORIZED: u64 = 1;
    /// Pool was not found
    const E_POOL_NOT_FOUND: u64 = 2;
    /// Pool size is invalid (must be between MIN_POOL_SIZE and MAX_POOL_SIZE)
    const E_INVALID_POOL_SIZE: u64 = 3;
    /// Insufficient funds for the operation
    const E_INSUFFICIENT_FUNDS: u64 = 4;
    /// Pool is already active
    const E_POOL_ALREADY_ACTIVE: u64 = 5;
    /// Member not found in the pool
    const E_MEMBER_NOT_FOUND: u64 = 6;
    /// Invalid position index
    const E_INVALID_POSITION: u64 = 7;
    /// Pool is not ready for this operation
    const E_POOL_NOT_READY: u64 = 8;
    /// Auction has already ended
    const E_AUCTION_ENDED: u64 = 9;
    /// Bid amount is too low
    const E_BID_TOO_LOW: u64 = 10;
    /// Auction is not currently active
    const E_AUCTION_NOT_ACTIVE: u64 = 11;
    /// No winner found for the auction
    const E_NO_WINNER: u64 = 12;

    const SECONDS_PER_MONTH: u64 = 2592000;
    const MIN_POOL_SIZE: u8 = 3;
    const MAX_POOL_SIZE: u8 = 10;
    const PRECISION: u64 = 10000;

    // === STRUCTS ===

    struct Bid has copy, drop, store {
        bidder: address,
        amount: u64,
    }

    struct Position has copy, drop, store {
        index: u8,
        order_token_addr: address,
        funded: bool,
        has_received_yield: bool,
    }

    struct BoosterInfo has copy, drop, store {
        address: address,
        boost_amount: u64,
    }

    struct CommonFundPool has key {
        pool_id: u64,
        creator: address,
        target_size: u8,
        contribution_per_member: u64,
        total_locked_required: u64,

        current_position: u8,
        auction_end_time: u64,
        auction_duration: u64,
        bids: vector<Bid>,
        auction_highest_bidder: address,
        auction_highest_bid: u64,
        bid_vault: Coin<AptosCoin>,

        collection_name: String,
        positions: vector<Position>,

        pool_balance: Coin<AptosCoin>,
        boost_percentage: u64,
        boosters: vector<BoosterInfo>,

        cycle_duration: u64,
        current_cycle: u8,
        last_distribution_time: u64,
        is_active: bool,
        completed: bool,
    }

    struct PoolRegistry has key {
        next_pool_id: u64,
        total_pools: u64,
    }

    #[event]
    struct PoolCreatedEvent has drop, store {
        pool_id: u64,
        creator: address,
        target_size: u8,
    }

    #[event]
    struct BidEvent has drop, store {
        pool_id: u64,
        bidder: address,
        amount: u64,
        position: u8,
    }

    #[event]
    struct OrderMintedEvent has drop, store {
        pool_id: u64,
        position: u8,
        winner: address,
        amount: u64,
    }

    #[event]
    struct YieldDistributedEvent has drop, store {
        pool_id: u64,
        recipient: address,
        amount: u64,
        cycle: u8,
    }

    #[event]
    struct BoostEvent has drop, store {
        pool_id: u64,
        booster: address,
        amount: u64,
        cycle: u8,
    }

    // === INITIALIZATION ===

    fun init_module(admin: &signer) {
        move_to(admin, PoolRegistry { 
            next_pool_id: 1, 
            total_pools: 0 
        });
    }

    // === UTILITY FUNCTIONS ===

    fun make_collection_name(pool_id: u64): String {
        let prefix = string::utf8(b"Trustless ROSCA Pool #");
        let id_str = int_to_string_u64(pool_id);
        prefix.append(id_str);
        prefix
    }

    fun int_to_string_u64(n: u64): String {
        if (n == 0) { 
            return string::utf8(b"0")
        };
        
        let digits = vector::empty<u8>();
        let n_copy = n;
        while (n_copy > 0) {
            let d = ((n_copy % 10) as u8) + 48u8;
            digits.push_back(d);
            n_copy /= 10;
        };
        
        let len = digits.length();
        let i = 0;
        let out = vector::empty<u8>();
        while (i < len) {
            let ch = digits[len - 1 - i];
            out.push_back(ch);
            i += 1;
        };
        string::utf8(out)
    }

    fun make_order_name(index: u8): String {
        let prefix = string::utf8(b"Order #");
        let idx_str = int_to_string_u64((index as u64));
        prefix.append(idx_str);
        prefix
    }

    fun all_positions_funded(positions: &vector<Position>): bool {
        let len = positions.length();
        let i = 0;
        while (i < len) {
            let position = positions.borrow(i);
            if (!position.funded) { 
                return false 
            };
            i += 1;
        };
        true
    }

    // === POOL MANAGEMENT ===

    public entry fun create_pool(
        creator: &signer,
        target_size: u8,
        contribution_per_member: u64,
        cycle_duration_months: u64,
        boost_percentage: u64,
        auction_duration_secs: u64,
    ) acquires PoolRegistry {
        let creator_addr = signer::address_of(creator);
        assert!(target_size >= MIN_POOL_SIZE && target_size <= MAX_POOL_SIZE, E_INVALID_POOL_SIZE);
        assert!(boost_percentage <= PRECISION, E_INVALID_POOL_SIZE);

        let registry = borrow_global_mut<PoolRegistry>(@retamifi);
        let pool_id = registry.next_pool_id;
        registry.next_pool_id += 1;
        registry.total_pools += 1;

        let collection_name = make_collection_name(pool_id);

        collection::create_unlimited_collection(
            creator,
            string::utf8(b"ROSCA Order NFTs"),
            collection_name,
            option::none(),
            string::utf8(b"https://retamifi.com/nft/")
        );

        let pool = CommonFundPool {
            pool_id,
            creator: creator_addr,
            target_size,
            contribution_per_member,
            total_locked_required: (contribution_per_member * (target_size as u64)),

            current_position: 0,
            auction_end_time: timestamp::now_seconds() + auction_duration_secs,
            auction_duration: auction_duration_secs,
            bids: vector::empty<Bid>(),
            auction_highest_bidder: @0x0,
            auction_highest_bid: 0,
            bid_vault: coin::zero<AptosCoin>(),

            collection_name,
            positions: vector::empty<Position>(),

            pool_balance: coin::zero<AptosCoin>(),
            boost_percentage,
            boosters: vector::empty<BoosterInfo>(),

            cycle_duration: cycle_duration_months * SECONDS_PER_MONTH,
            current_cycle: 0,
            last_distribution_time: 0,
            is_active: false,
            completed: false,
        };

        event::emit(PoolCreatedEvent {
            pool_id,
            creator: creator_addr,
            target_size
        });

        move_to(creator, pool);
    }

    fun complete_pool(pool: &mut CommonFundPool) {
        let len = pool.positions.length();
        let i = 0;
        
        while (i < len) {
            let position = pool.positions.borrow(i);
            let token_object = object::address_to_object<token::Token>(position.order_token_addr);
            let owner_addr = object::owner(token_object);
            
            let principal = coin::extract(&mut pool.pool_balance, pool.contribution_per_member);
            coin::deposit(owner_addr, principal);
            
            i += 1;
        };
        
        pool.completed = true;
    }

    // === AUCTION SYSTEM ===

    public entry fun place_bid(
        bidder: &signer, 
        pool_creator: address, 
        bid_amount: u64
    ) acquires CommonFundPool {
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        let now = timestamp::now_seconds();
        assert!(now < pool.auction_end_time, E_AUCTION_ENDED);
        assert!(bid_amount > pool.auction_highest_bid, E_BID_TOO_LOW);

        if (pool.auction_highest_bidder != @0x0) {
            let refund = coin::extract(&mut pool.bid_vault, pool.auction_highest_bid);
            coin::deposit(pool.auction_highest_bidder, refund);
        };

        let coins = coin::withdraw<AptosCoin>(bidder, bid_amount);
        coin::merge(&mut pool.bid_vault, coins);

        pool.auction_highest_bidder = signer::address_of(bidder);
        pool.auction_highest_bid = bid_amount;

        event::emit(BidEvent {
            pool_id: pool.pool_id,
            bidder: signer::address_of(bidder),
            amount: bid_amount,
            position: pool.current_position + 1
        });
    }

    public entry fun finalize_auction(
        caller: &signer, 
        pool_creator: address
    ) acquires CommonFundPool {
        let caller_addr = signer::address_of(caller);
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        assert!(caller_addr == pool.creator, E_NOT_AUTHORIZED);
        
        let now = timestamp::now_seconds();
        assert!(now >= pool.auction_end_time, E_AUCTION_NOT_ACTIVE);
        assert!(pool.current_position < pool.target_size, E_POOL_ALREADY_ACTIVE);

        let winner = pool.auction_highest_bidder;
        let winning_amount = pool.auction_highest_bid;
        assert!(winner != @0x0, E_NO_WINNER);

        let pos_index = pool.current_position + 1;
        let token_name = make_order_name(pos_index);

        let token_constructor = token::create_named_token(
            caller,
            pool.collection_name,
            string::utf8(b"ROSCA Order NFT"),
            token_name,
            option::none(),
            string::utf8(b"https://retamifi.com/nft/metadata/")
        );

        let token_object = object::object_from_constructor_ref<token::Token>(&token_constructor);
        let token_address = object::object_address(&token_object);

        object::transfer(caller, token_object, winner);

        let position = Position {
            index: pos_index,
            order_token_addr: token_address,
            funded: false,
            has_received_yield: false
        };
        pool.positions.push_back(position);

        if (winning_amount > 0) {
            let premium = coin::extract(&mut pool.bid_vault, winning_amount);
            coin::merge(&mut pool.pool_balance, premium);
        };

        event::emit(OrderMintedEvent {
            pool_id: pool.pool_id,
            position: pos_index,
            winner,
            amount: winning_amount
        });

        pool.current_position += 1;
        if (pool.current_position < pool.target_size) {
            pool.auction_end_time = now + pool.auction_duration;
            pool.auction_highest_bidder = @0x0;
            pool.auction_highest_bid = 0;
        } else {
            pool.auction_end_time = 0;
        };
    }

    // === FUNDING SYSTEM ===

    public entry fun lock_funds(
        owner: &signer, 
        pool_creator: address
    ) acquires CommonFundPool {
        let owner_addr = signer::address_of(owner);
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        assert!(!pool.completed, E_POOL_NOT_READY);

        let len = pool.positions.length();
        let i = 0;
        let found = false;
        
        while (i < len && !found) {
            let position_ref = pool.positions.borrow_mut(i);
            if (!position_ref.funded) {
                let token_addr = position_ref.order_token_addr;
                
                let token_object = object::address_to_object<token::Token>(token_addr);
                if (object::is_owner(token_object, owner_addr)) {
                    let coins = coin::withdraw<AptosCoin>(owner, pool.contribution_per_member);
                    coin::merge(&mut pool.pool_balance, coins);
                    position_ref.funded = true;
                    found = true;
                };
            };
            i += 1;
        };
        
        assert!(found, E_NOT_AUTHORIZED);

        if (all_positions_funded(&pool.positions)) {
            pool.is_active = true;
            pool.last_distribution_time = timestamp::now_seconds();
        };
    }

    // === BOOST SYSTEM ===

    public entry fun boost(
        booster: &signer, 
        pool_creator: address, 
        boost_amount: u64
    ) acquires CommonFundPool {
        let booster_addr = signer::address_of(booster);
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        assert!(pool.is_active && !pool.completed, E_POOL_NOT_READY);

        let main_pos_index = (pool.current_cycle as u64);
        if (main_pos_index < pool.positions.length()) {
            let main_position = pool.positions.borrow(main_pos_index);
            let token_object = object::address_to_object<token::Token>(main_position.order_token_addr);
            assert!(!object::is_owner(token_object, booster_addr), E_NOT_AUTHORIZED);
        };

        let coins = coin::withdraw<AptosCoin>(booster, boost_amount);
        coin::merge(&mut pool.pool_balance, coins);

        let booster_info = BoosterInfo { 
            address: booster_addr, 
            boost_amount 
        };
        pool.boosters.push_back(booster_info);

        event::emit(BoostEvent {
            pool_id: pool.pool_id,
            booster: booster_addr,
            amount: boost_amount,
            cycle: pool.current_cycle
        });
    }

    fun distribute_boost_share(pool: &mut CommonFundPool, total_boost_share: u64) {
        if (total_boost_share == 0 || pool.boosters.is_empty()) { 
            return 
        };
        
        let len = pool.boosters.length();
        let i = 0;
        let total_boost_amount = 0;
        
        while (i < len) {
            let booster = pool.boosters.borrow(i);
            total_boost_amount += booster.boost_amount;
            i += 1;
        };
        
        if (total_boost_amount == 0) { 
            return 
        };

        let j = 0;
        while (j < len) {
            let booster = pool.boosters.borrow(j);
            let share = (total_boost_share * booster.boost_amount) / total_boost_amount;
            
            if (share > 0) {
                let coins = coin::extract(&mut pool.pool_balance, share);
                coin::deposit(booster.address, coins);
                
                event::emit(YieldDistributedEvent {
                    pool_id: pool.pool_id,
                    recipient: booster.address,
                    amount: share,
                    cycle: pool.current_cycle
                });
            };
            
            j += 1;
        };
    }

    // === YIELD DISTRIBUTION ===

    public entry fun claim_yield(
        _caller: &signer, 
        pool_creator: address, 
        total_yield: u64
    ) acquires CommonFundPool {
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        assert!(pool.is_active && !pool.completed, E_POOL_NOT_READY);
        
        let now = timestamp::now_seconds();
        assert!(now >= pool.last_distribution_time + pool.cycle_duration, E_POOL_NOT_READY);

        let cycle_index = (pool.current_cycle as u64);
        assert!(cycle_index < pool.positions.length(), E_INVALID_POSITION);
        
        let main_share = if (pool.boosters.is_empty()) {
            total_yield
        } else {
            let total_boost_share = (total_yield * pool.boost_percentage) / PRECISION;
            distribute_boost_share(pool, total_boost_share);
            total_yield - total_boost_share
        };

        let position_ref = pool.positions.borrow_mut(cycle_index);
        let token_object = object::address_to_object<token::Token>(position_ref.order_token_addr);
        let owner_addr = object::owner(token_object);

        if (main_share > 0) {
            let coins = coin::extract(&mut pool.pool_balance, main_share);
            coin::deposit(owner_addr, coins);
            
            event::emit(YieldDistributedEvent {
                pool_id: pool.pool_id,
                recipient: owner_addr,
                amount: main_share,
                cycle: pool.current_cycle + 1
            });
        };

        position_ref.has_received_yield = true;
        pool.current_cycle += 1;
        pool.last_distribution_time = now;
        pool.boosters = vector::empty<BoosterInfo>();

        if ((pool.current_cycle as u64) >= (pool.target_size as u64)) {
            complete_pool(pool);
        };
    }
}