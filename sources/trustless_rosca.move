/// Trustless ROSCA (Rotating Savings and Credit Association) smart contract
/// Implements a decentralized savings pool where members contribute funds and take turns
/// receiving payouts through an auction mechanism with optional yield boosting
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

    /// Number of seconds in a month (30 days)
    const SECONDS_PER_MONTH: u64 = 2592000;
    /// Minimum number of members allowed in a pool
    const MIN_POOL_SIZE: u8 = 3;
    /// Maximum number of members allowed in a pool
    const MAX_POOL_SIZE: u8 = 10;
    /// Precision factor for percentage calculations (100% = 10000)
    const PRECISION: u64 = 10000;

    /// Default booster yield percentage (5% = 500/10000)
    const DEFAULT_BOOSTER_YIELD_PERCENTAGE: u64 = 500;

    // === STRUCTS ===

    /// Represents a bid placed during an auction
    struct Bid has copy, drop, store {
        bidder: address,
        amount: u64,
    }

    /// Represents a position/slot in the ROSCA pool
    struct Position has copy, drop, store {
        index: u8,
        order_token_addr: address,
        funded: bool,
        has_received_yield: bool,
        booster_yield_percentage: u64,
        boosters: vector<BoosterInfo>
    }

    /// Information about a user who has boosted a position
    struct BoosterInfo has copy, drop, store {
        address: address,
        boost_amount: u64,
    }

    /// Main ROSCA pool resource
    struct CommonFundPool has key {
        pool_id: u64,
        creator: address,
        max_members: u8,
        contribution_per_member: u64,

        current_position: u8,
        auction_start_time_secs: u64,
        auction_end_time_secs: u64,
        bids: vector<Bid>,
        auction_highest_bidder: address,
        auction_highest_bid: u64,
        auction_highest_booster_yield_percetange: u64,
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

    /// Global registry to track all pools
    struct PoolRegistry has key {
        next_pool_id: u64,
        total_pools: u64,
    }


    #[event]
    struct PoolCreatedEvent has drop, store {
        pool_id: u64,
        creator: address,
        max_members: u8,
    }

    #[event]
    struct BidEvent has drop, store {
        pool_id: u64,
        bidder: address,
        amount: u64,
        position: u8,
        booster_yield_percentage: u64,
    }

    #[event]
    struct OrderMintedEvent has drop, store {
        pool_id: u64,
        position: u8,
        winner: address,
        amount: u64,
        booster_yield_percentage: u64,
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
    
    /// Create a new ROSCA pool with specified parameters
    /// @param creator - Signer creating the pool
    /// @param max_members - Maximum number of members (3-10)
    /// @param contribution_per_member - Amount each member must contribute
    /// @param cycle_duration_months - Duration of each cycle in months
    /// @param boost_percentage - Percentage of yield shared with boosters
    /// @param auction_start_time_secs - When the first auction starts
    /// @param auction_end_time_secs - When the first auction ends
    public entry fun create_pool(
        creator: &signer,
        max_members: u8,
        contribution_per_member: u64,
        cycle_duration_months: u64,
        boost_percentage: u64,
        auction_start_time_secs: u64,
        auction_end_time_secs: u64
    ) acquires PoolRegistry {
        let creator_addr = signer::address_of(creator);
        assert!(max_members >= MIN_POOL_SIZE && max_members <= MAX_POOL_SIZE, E_INVALID_POOL_SIZE);
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
            max_members,
            contribution_per_member,

            current_position: 0,
            auction_start_time_secs,
            auction_end_time_secs,
            bids: vector::empty<Bid>(),
            auction_highest_bidder: @0x0,
            auction_highest_bid: 0,
            auction_highest_booster_yield_percetange: DEFAULT_BOOSTER_YIELD_PERCENTAGE,
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
            max_members
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

    /// Place a bid in the current auction for a position
    /// @param bidder - Signer placing the bid
    /// @param pool_creator - Address of the pool creator
    /// @param bid_amount - Amount to bid
    /// @param booster_yield_percentage - Percentage of yield to share with boosters
    public entry fun place_bid(
        bidder: &signer, 
        pool_creator: address, 
        bid_amount: u64,
        booster_yield_percentage: u64
    ) acquires CommonFundPool {
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        let now = timestamp::now_seconds();
        assert!(now < pool.auction_end_time_secs, E_AUCTION_ENDED);

        assert!(bid_amount > pool.auction_highest_bid, E_BID_TOO_LOW);
        assert!(booster_yield_percentage <= PRECISION, E_INVALID_POOL_SIZE);

        if (pool.auction_highest_bidder != @0x0) {
            let refund = coin::extract(&mut pool.bid_vault, pool.auction_highest_bid);
            coin::deposit(pool.auction_highest_bidder, refund);
        };

        let coins = coin::withdraw<AptosCoin>(bidder, bid_amount);
        coin::merge(&mut pool.bid_vault, coins);

        pool.auction_highest_bidder = signer::address_of(bidder);
        pool.auction_highest_bid = bid_amount;
        pool.auction_highest_booster_yield_percetange = booster_yield_percentage;

        event::emit(BidEvent {
            pool_id: pool.pool_id,
            bidder: signer::address_of(bidder),
            amount: bid_amount,
            position: pool.current_position + 1,
            booster_yield_percentage
        });
    }

    /// Finalize the current auction and mint order NFT to winner
    /// Only callable by pool creator after auction ends
    /// @param caller - Pool creator finalizing the auction
    /// @param pool_creator - Address of the pool creator
    public entry fun finalize_auction(
        caller: &signer, 
        pool_creator: address
    ) acquires CommonFundPool {
        let caller_addr = signer::address_of(caller);
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        assert!(caller_addr == pool.creator, E_NOT_AUTHORIZED);
        
        let now = timestamp::now_seconds();
        assert!(now >= pool.auction_end_time_secs, E_AUCTION_NOT_ACTIVE);
        assert!(pool.current_position < pool.max_members, E_POOL_ALREADY_ACTIVE);

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
        let token_addr = object::object_address(&token_object);

        object::transfer(caller, token_object, winner);

        let position = Position {
            index: pos_index,
            order_token_addr: token_addr,
            funded: false,
            has_received_yield: false,
            booster_yield_percentage: pool.auction_highest_booster_yield_percetange,
            boosters: vector::empty<BoosterInfo>()
        };
        pool.positions.push_back(position);
        pool.positions.push_back(position);

        if (winning_amount > 0) {
            let premium = coin::extract(&mut pool.bid_vault, winning_amount);
            coin::merge(&mut pool.pool_balance, premium);
        };

        event::emit(OrderMintedEvent {
            pool_id: pool.pool_id,
            position: pos_index,
            winner,
            amount: winning_amount,
            booster_yield_percentage: pool.auction_highest_booster_yield_percetange
        });

        pool.current_position += 1;
        if (pool.current_position < pool.max_members) {
            pool.auction_end_time_secs = now + pool.cycle_duration;
            pool.auction_highest_bidder = @0x0;
            pool.auction_highest_bid = 0;
            pool.auction_highest_booster_yield_percetange = DEFAULT_BOOSTER_YIELD_PERCENTAGE;
        } else {
            pool.auction_end_time_secs = 0;
        };
    }

    // === FUNDING SYSTEM ===

    /// Lock contribution funds for a position holder
    /// Must be called by NFT holder to fund their position
    /// @param owner - Signer who owns a position NFT
    /// @param pool_creator - Address of the pool creator
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

    /// Boost the current cycle's position with additional funds
    /// Boosters receive a share of the yield proportional to their contribution
    /// @param booster - Signer providing the boost
    /// @param pool_creator - Address of the pool creator
    /// @param boost_amount - Amount to boost in APT
    public entry fun boost(booster: &signer, pool_creator: address, boost_amount: u64) acquires CommonFundPool {
        let booster_addr = signer::address_of(booster);
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        assert!(pool.is_active && !pool.completed, E_POOL_NOT_READY);

        let main_pos_index = pool.current_cycle as u64;
        if (main_pos_index < pool.positions.length()) {
            let main_pos = pool.positions.borrow(main_pos_index);
            let token_obj = object::address_to_object<token::Token>(main_pos.order_token_addr);
            assert!(!object::is_owner(token_obj, booster_addr), E_NOT_AUTHORIZED);
        };

        let coins = coin::withdraw<AptosCoin>(booster, boost_amount);
        coin::merge(&mut pool.pool_balance, coins);

        let booster_info = BoosterInfo { address: booster_addr, boost_amount };
        let main_pos_mut = pool.positions.borrow_mut(main_pos_index as u64);
        main_pos_mut.boosters.push_back(booster_info);

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

    /// Claim and distribute yield for the current cycle
    /// Distributes yield to position holder and boosters based on boost percentages
    /// @param _caller - Signer calling this function (unused but kept for interface)
    /// @param pool_creator - Address of the pool creator
    /// @param total_yield - Total yield amount to distribute
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

        if ((pool.current_cycle as u64) >= (pool.max_members as u64)) {
            complete_pool(pool);
        };
    }
}