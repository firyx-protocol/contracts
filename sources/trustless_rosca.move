module retamifi::rosca_core {
    use std::signer;
    use std::vector;
    use std::option::{Self, Option};
    use std::string::{String};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::event;

    /// Error: Caller is not authorized to perform this action
    const E_NOT_AUTHORIZED: u64 = 1;

    /// Error: Pool does not exist at the given address
    const E_POOL_NOT_FOUND: u64 = 2;

    /// Error: Pool size is invalid (too small, too large, or inconsistent)
    const E_INVALID_POOL_SIZE: u64 = 3;

    /// Error: Insufficient funds for the requested operation
    const E_INSUFFICIENT_FUNDS: u64 = 4;

    /// Error: Attempted to activate a pool that is already active
    const E_POOL_ALREADY_ACTIVE: u64 = 5;

    /// Error: Member not found in the pool
    const E_MEMBER_NOT_FOUND: u64 = 6;

    /// Error: Invalid member position/index in pool
    const E_INVALID_POSITION: u64 = 7;

    /// Error: Pool not ready for the requested operation (e.g., distribution too early)
    const E_POOL_NOT_READY: u64 = 8;

    const SECONDS_PER_MONTH: u64 = 2592000;
    const MIN_POOL_SIZE: u8 = 3;
    const MAX_POOL_SIZE: u8 = 10;
    const PRECISION: u64 = 10000;

    struct MemberInfo has copy, drop, store {
        address: address,
        locked_amount: u64,
        position: u8,
        has_received_yield: bool,
        join_time: u64,
        boost_contributions: u64,
    }

    struct BoosterInfo has copy, drop, store {
    address: address,
    boost_amount: u64,
    }

    struct CommonFundPool has key {
        pool_id: u64,
        creator: address,
        members: vector<MemberInfo>,
        total_locked: u64,
        current_cycle: u8,
        cycle_duration: u64,
        pool_balance: Coin<AptosCoin>,
        strategy_id: String,
        boosters: vector<BoosterInfo>,
        boost_percentage: u64, // e.g., 1000 = 10% (PRECISION = 10000)
        creation_time: u64,
        last_distribution_time: u64,
        is_active: bool,
        completed: bool,
    }

    struct PoolRegistry has key {
        next_pool_id: u64,
        total_pools: u64,
        active_pools: u64,
    }

    #[event]
    struct PoolCreatedEvent has drop, store {
        pool_id: u64,
        creator: address,
        member_count: u8,
        total_amount: u64,
        strategy_id: String,
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

    fun init_module(admin: &signer) {
        move_to(admin, PoolRegistry {
            next_pool_id: 1,
            total_pools: 0,
            active_pools: 0,
        });
    }

    public entry fun create_pool(
        creator: &signer,
        member_addresses: vector<address>,
        contribution_per_member: u64,
        strategy_id: String,
        cycle_duration_months: u64,
        boost_percentage: u64,
    ) acquires PoolRegistry {
        let creator_addr = signer::address_of(creator);
        let member_count = member_addresses.length();
        
        // Validations
        assert!(member_count >= (MIN_POOL_SIZE as u64) && member_count <= (MAX_POOL_SIZE as u64), E_INVALID_POOL_SIZE);
        
        // Get next pool ID
        let registry = borrow_global_mut<PoolRegistry>(@retamifi);
        let pool_id = registry.next_pool_id;
        registry.next_pool_id += 1;
        registry.total_pools += 1;

        // Create member list
        let members = vector::empty<MemberInfo>();
        let i = 0;
        while (i < member_count) {
            let member_addr = member_addresses[i];
            let member = MemberInfo {
                address: member_addr,
                locked_amount: contribution_per_member,
                position: (i + 1) as u8,
                has_received_yield: false,
                join_time: timestamp::now_seconds(),
                boost_contributions: 0,
            };
            members.push_back(member);
            i += 1;
        };

        // Create pool resource
        let pool = CommonFundPool {
            pool_id,
            creator: creator_addr,
            members,
            total_locked: contribution_per_member * member_count,
            current_cycle: 0,
            cycle_duration: cycle_duration_months * SECONDS_PER_MONTH,
            pool_balance: coin::zero<AptosCoin>(),
            strategy_id,
            boosters: vector::empty<BoosterInfo>(),
            boost_percentage,
            creation_time: timestamp::now_seconds(),
            last_distribution_time: 0,
            is_active: false,
            completed: false,
        };

        // Emit event
        event::emit(PoolCreatedEvent {
            pool_id,
            creator: creator_addr,
            member_count: (member_count as u8),
            total_amount: contribution_per_member * member_count,
            strategy_id,
        });

        // Move pool resource to creator's account
        move_to(creator, pool);
    }

    public entry fun lock_funds(
        member: &signer,
        pool_creator: address,
        amount: u64,
    ) acquires CommonFundPool {
        let member_addr = signer::address_of(member);
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        
        // Find member in pool
        let member_index = find_member_index(pool, member_addr);
        assert!(member_index.is_some(), E_MEMBER_NOT_FOUND);
        
        let index = member_index.extract();
        let member_info = pool.members.borrow(index);
        
        // Validate amount
        assert!(amount == member_info.locked_amount, E_INSUFFICIENT_FUNDS);
        
        // Transfer coins to pool
        let coins = coin::withdraw<AptosCoin>(member, amount);
        coin::merge(&mut pool.pool_balance, coins);
        
        // Check if all members have locked funds
        if (coin::value(&pool.pool_balance) == pool.total_locked) {
            pool.is_active = true;
            pool.last_distribution_time = timestamp::now_seconds();
        };
    }

    public entry fun claim_yield(
        pool_creator: address,
        total_yield: u64,
    ) acquires CommonFundPool {
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        assert!(pool.is_active && !pool.completed, E_POOL_NOT_READY);
        
        // Check if it's time for next distribution
        let current_time = timestamp::now_seconds();
        assert!(current_time >= pool.last_distribution_time + pool.cycle_duration, E_POOL_NOT_READY);
        
        // Get current cycle recipient (main member)
        let current_cycle = pool.current_cycle;
        let main_member_addr = pool.members[(current_cycle as u64)].address;
        
        let main_share: u64;
        
        // Check if there are boosters
        if (pool.boosters.is_empty()) {
            // No boosters - main member gets 100% yield
            main_share = total_yield;
        } else {
            let total_boost_share: u64;
            // Has boosters - calculate cut
            total_boost_share = (total_yield * pool.boost_percentage) / PRECISION;
            main_share = total_yield - total_boost_share;
            
            // Distribute boost share among boosters proportionally
            distribute_boost_share(pool, total_boost_share);
        };
        
        // Transfer main share to primary recipient
        if (main_share > 0) {
            let main_coins = coin::extract(&mut pool.pool_balance, main_share);
            coin::deposit(main_member_addr, main_coins);
            
            // Emit event for main distribution
            event::emit(YieldDistributedEvent {
                pool_id: pool.pool_id,
                recipient: main_member_addr,
                amount: main_share,
                cycle: current_cycle + 1,
            });
        };

        let main_member = pool.members.borrow_mut((current_cycle as u64));

        // Update member status
        main_member.has_received_yield = true;
        
        // Reset boosters for next cycle
        pool.boosters = vector::empty<BoosterInfo>();
        
        // Move to next cycle
        pool.current_cycle += 1;
        pool.last_distribution_time = current_time;
        
        // Check if pool is completed
        if (pool.current_cycle >= (pool.members.length() as u8)) {
            complete_pool(pool);
        };
    }

    public entry fun boost(
        booster: &signer,
        pool_creator: address,
        boost_amount: u64,
    ) acquires CommonFundPool {
        let booster_addr = signer::address_of(booster);
        let pool = borrow_global_mut<CommonFundPool>(pool_creator);
        
        assert!(pool.is_active && !pool.completed, E_POOL_NOT_READY);
        
        // Ensure booster is not the current cycle recipient
        let current_recipient = pool.members.borrow((pool.current_cycle as u64));
        assert!(booster_addr != current_recipient.address, E_NOT_AUTHORIZED);
        
        // Verify booster is a pool member
        let booster_index = find_member_index(pool, booster_addr);
        assert!(booster_index.is_some(), E_MEMBER_NOT_FOUND);
        
        // Add boost contribution
        let boost_coins = coin::withdraw<AptosCoin>(booster, boost_amount);
        coin::merge(&mut pool.pool_balance, boost_coins);
        
        // Add to boosters list
        let booster_info = BoosterInfo {
            address: booster_addr,
            boost_amount,
        };
        pool.boosters.push_back(booster_info);
        
        // Emit event
        event::emit(BoostEvent {
            pool_id: pool.pool_id,
            booster: booster_addr,
            amount: boost_amount,
            cycle: pool.current_cycle,
        });
    }

    fun distribute_boost_share(pool: &mut CommonFundPool, total_boost_share: u64) {
        if (total_boost_share == 0 || pool.boosters.is_empty()) {
            return
        };
        
        // Calculate total boost amount to determine proportions
        let total_boost_amount = 0u64;
        let i = 0;
        let boosters_len = pool.boosters.length();
        
        while (i < boosters_len) {
            let booster = pool.boosters.borrow(i);
            total_boost_amount += booster.boost_amount;
            i += 1;
        };
        
        // Distribute proportionally
        i = 0;
        while (i < boosters_len) {
            let booster = pool.boosters.borrow(i);
            let booster_share = (total_boost_share * booster.boost_amount) / total_boost_amount;
            
            if (booster_share > 0) {
                let booster_coins = coin::extract(&mut pool.pool_balance, booster_share);
                coin::deposit(booster.address, booster_coins);
                
                // Emit event for booster distribution
                event::emit(YieldDistributedEvent {
                    pool_id: pool.pool_id,
                    recipient: booster.address,
                    amount: booster_share,
                    cycle: pool.current_cycle + 1,
                });
            };
            
            i += 1;
        };
    }

    fun complete_pool(pool: &mut CommonFundPool) {
        // Return locked principal to each member
        let i = 0;
        let member_count = pool.members.length();
        
        while (i < member_count) {
            let member_info = pool.members.borrow(i);
            let principal_coins = coin::extract(&mut pool.pool_balance, member_info.locked_amount);
            coin::deposit(member_info.address, principal_coins);
            i += 1;
        };
        
        pool.completed = true;
    }

    fun find_member_index(pool: &CommonFundPool, member_addr: address): Option<u64> {
        let i = 0;
        let len = pool.members.length();
        
        while (i < len) {
            let member = pool.members.borrow(i);
            if (member.address == member_addr) {
                return option::some(i)
            };
            i += 1;
        };
        
        option::none<u64>()
    }
}