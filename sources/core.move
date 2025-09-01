module disentry::core {
    use std::signer;
    use std::string::{Self, String};
    use std::option::{Self, Option};
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::bcs;
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::function_info;
    use aptos_framework::timestamp;
    use aptos_framework::hash;
    use aptos_framework::debug;

    use disentry::math::{to_decimals, from_decimals};

    friend disentry::hyperion_wrapper;
    
    // === ERROR CODES ===
    
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 3;
    const E_COMPOUND_TOO_SMALL: u64 = 4;
    const E_THERMAL_ENGINE_NOT_INITIALIZED: u64 = 5;

    // === TOKEN CONSTANTS ===

    const DECIMALS: u8 = 8;
    const MAXIMUM_SUPPLY: u128 = 1000000000 * 100000000; // 1 Billion tokens with 8 decimals
    const DIS_TOKEN_NAME: vector<u8> = b"Disentry LP Token";
    const DIS_TOKEN_SYMBOL: vector<u8> = b"dLP";

    // === REWARD CONSTANTS ===

    const MIN_COMPOUND_THRESHOLD: u64 = 1000000; // 0.01 tokens
    const BASE_APY: u64 = 1500; // 15% APY (baseline)
    const SECONDS_PER_YEAR: u64 = 31536000; // 365 * 24 * 60 * 60

    // === THERMAL CONSTANTS ===

    const BASE_TEMPERATURE: u64 = 5000; // 50°C baseline
    const THERMAL_CONDUCTIVITY: u64 = 100; // Heat transfer rate
    const TEMPERATURE_PRECISION: u64 = 100; // 1°C precision
    const MAX_THERMAL_POOLS: u64 = 10;

    // === STORAGE STRUCTS ===

    /// Stores token controller references and global statistics
    struct DisTokenController has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
        total_supply: u64,
        total_rewards_distributed: u64,
    }

    /// User's vault position including stake amount and rewards data
    struct VaultPosition has key {
        token_amount: u64,
        last_compound_timestamp: u64,
        total_rewards_earned: u64,
        deposit_timestamp: u64,
        thermal_pool_id: u64, // Which thermal pool user belongs to
    }

    /// Thermal pool data for dynamic yield calculation
    struct ThermalPool has store {
        total_liquidity: u64,          // Total tokens in this pool
        active_users: u64,             // Number of active users (updated on deposit/withdraw)
        last_activity_timestamp: u64,  // When last deposit/withdraw happened
        cumulative_volume: u64,        // Total volume processed
        pool_creation_time: u64,       // Pool age for maturity bonus
        temperature_cache: u64,        // Cached temperature to avoid recalc
        last_temperature_update: u64,  // When temperature was last calculated
        update_cooldown: u64,          // Cooldown period for updates
        pending_updates: u64,          // Pending updates to apply
    }

    /// System-wide thermal engine configuration
    struct ThermalEngine has key {
        pools: vector<ThermalPool>,
        equilibrium_temperature: u64,  // Target temperature for all pools
        last_equilibration_time: u64,  // When pools were last balanced
        equilibration_interval: u64,   // How often to run equilibration (3600s = 1h)
        total_system_energy: u64,      // Total energy in all pools
    }

    // === INITIALIZATION FUNCTIONS ===

    fun init_module(admin: &signer) {
        let constructor_ref = object::create_named_object(admin, DIS_TOKEN_SYMBOL);
        
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::some(MAXIMUM_SUPPLY),
            string::utf8(DIS_TOKEN_NAME),
            string::utf8(DIS_TOKEN_SYMBOL),
            DECIMALS,
            string::utf8(b"https://disentry.com/logo.png"),
            string::utf8(b"https://disentry.com"),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let transfer_ref = fungible_asset::generate_transfer_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let withdraw_function = function_info::new_function_info(
            admin,
            string::utf8(b"core"),
            string::utf8(b"on_withdraw"),
        );

        let deposit_function = function_info::new_function_info(
            admin,
            string::utf8(b"core"),
            string::utf8(b"on_deposit"),
        );

        let derived_balance_function = function_info::new_function_info(
            admin,
            string::utf8(b"core"),
            string::utf8(b"on_derived_balance"),
        );

        dispatchable_fungible_asset::register_dispatch_functions(
            &constructor_ref,
            option::some(withdraw_function),
            option::some(deposit_function),
            option::some(derived_balance_function),
        );

        let controller = DisTokenController {
            mint_ref,
            transfer_ref,
            burn_ref,
            total_supply: 0,
            total_rewards_distributed: 0,
        };

        move_to(admin, controller);

        // Initialize Thermal Engine
        init_thermal_engine(admin);
    }

    fun init_thermal_engine(admin: &signer) {
        let current_time = timestamp::now_seconds();
        let pools = vector::empty<ThermalPool>();
        
        // Initialize 3 thermal pools
        let i = 0;
        while (i < 3) {
            pools.push_back(ThermalPool {
                total_liquidity: 0,
                active_users: 0,
                last_activity_timestamp: current_time,
                cumulative_volume: 0,
                pool_creation_time: current_time,
                temperature_cache: BASE_TEMPERATURE,
                last_temperature_update: current_time,
                update_cooldown: 1800,
                pending_updates: 0,
            });
            i += 1;
        };

        let thermal_engine = ThermalEngine {
            pools,
            equilibrium_temperature: BASE_TEMPERATURE,
            last_equilibration_time: current_time,
            equilibration_interval: 3600,
            total_system_energy: 0,
        };

        move_to(admin, thermal_engine);
    }

    // === CORE PUBLIC ENTRY FUNCTIONS ===

    /// Deposit liquidity into the protocol (basic version)
    public entry fun deposit_liquidity(
        user: &signer,
        amount: u64,
    ) acquires DisTokenController, VaultPosition, ThermalEngine {
        let user_addr = signer::address_of(user);
        
        let controller = borrow_global_mut<DisTokenController>(@disentry);
        let new_tokens = fungible_asset::mint(&controller.mint_ref, amount);
        
        if (!exists<VaultPosition>(user_addr)) {
            let thermal_pool_id = assign_thermal_pool(user_addr);
            let position = VaultPosition {
                token_amount: amount,
                last_compound_timestamp: timestamp::now_seconds(),
                total_rewards_earned: 0,
                deposit_timestamp: timestamp::now_seconds(),
                thermal_pool_id,
            };
            move_to(user, position);
            
            update_thermal_pool_activity_efficient(thermal_pool_id, amount);
        } else {
            let position = borrow_global_mut<VaultPosition>(user_addr);
            position.token_amount += amount;
            
            update_thermal_pool_activity_efficient(position.thermal_pool_id, amount);
        };

        primary_fungible_store::deposit_with_ref(
            &controller.transfer_ref,
            user_addr, 
            new_tokens
        );
        
        controller.total_supply += amount;
    }

    /// Withdraw liquidity from the protocol
    public entry fun withdraw_liquidity(
        user: &signer,
        amount: u64,
    ) acquires DisTokenController, VaultPosition, ThermalEngine {
        let user_addr = signer::address_of(user);
        let position = borrow_global_mut<VaultPosition>(user_addr);
        
        // Thermal auto-compound before withdraw
        thermal_auto_compound_internal(position, user_addr);
        
        assert!(position.token_amount >= amount, E_INSUFFICIENT_BALANCE);
        assert!(amount > 0, E_INVALID_AMOUNT);
        
        let controller = borrow_global_mut<DisTokenController>(@disentry);
        let tokens_to_burn = primary_fungible_store::withdraw_with_ref(
            &controller.transfer_ref,
            user_addr,
            amount
        );
        
        let position = borrow_global_mut<VaultPosition>(user_addr);
        position.token_amount -= amount;
        
        // Update thermal pool on withdrawal
        update_thermal_pool_activity(position.thermal_pool_id, amount, false);
        
        fungible_asset::burn(&controller.burn_ref, tokens_to_burn);
        controller.total_supply -= amount;
    }

    // === PUBLIC FUNCTIONS FOR INTEGRATION ===

    /// Mint dLP tokens (for integrations)
    public(friend) fun mint_dlp_tokens(amount: u64): FungibleAsset acquires DisTokenController {
        let controller = borrow_global_mut<DisTokenController>(@disentry);
        controller.total_supply += amount;
        fungible_asset::mint(&controller.mint_ref, amount)
    }

    /// Burn dLP tokens (for integrations)
    public(friend) fun burn_dlp_tokens(tokens: FungibleAsset) acquires DisTokenController {
        let amount = fungible_asset::amount(&tokens);
        let controller = borrow_global_mut<DisTokenController>(@disentry);
        controller.total_supply -= amount;
        fungible_asset::burn(&controller.burn_ref, tokens);
    }

    /// Create vault position (for integrations)
    public fun create_vault_position(
        user: &signer,
        token_amount: u64,
    ) acquires VaultPosition, ThermalEngine {
        let user_addr = signer::address_of(user);

        if (!exists<VaultPosition>(user_addr)) {
            let thermal_pool_id = assign_thermal_pool(user_addr);
            let position = VaultPosition {
                token_amount,
                last_compound_timestamp: timestamp::now_seconds(),
                total_rewards_earned: 0,
                deposit_timestamp: timestamp::now_seconds(),
                thermal_pool_id,
            };
            move_to(user, position);
            
            update_thermal_pool_activity_efficient(thermal_pool_id, token_amount);
        } else {
            let position = borrow_global_mut<VaultPosition>(user_addr);
            position.token_amount += token_amount;
            update_thermal_pool_activity_efficient(position.thermal_pool_id, token_amount);
        };
    }

    /// Update vault position (for integrations)
    public fun update_vault_position(
        user_addr: address,
        token_delta: u64,
        is_increase: bool,
    ) acquires VaultPosition, ThermalEngine {
        let position = borrow_global_mut<VaultPosition>(user_addr);
        
        if (is_increase) {
            position.token_amount += token_delta;
        } else {
            assert!(position.token_amount >= token_delta, E_INSUFFICIENT_BALANCE);
            position.token_amount -= token_delta;
        };
        
        update_thermal_pool_activity_efficient(position.thermal_pool_id, token_delta);
    }

    /// Deposit dLP tokens to user (for integrations)
    public(friend) fun deposit_dlp_to_user(user_addr: address, tokens: FungibleAsset) 
    acquires DisTokenController {
        let controller = borrow_global<DisTokenController>(@disentry);
        primary_fungible_store::deposit_with_ref(
            &controller.transfer_ref,
            user_addr, 
            tokens
        );
    }

    /// Withdraw dLP tokens from user (for integrations)
    public(friend) fun withdraw_dlp_from_user(user_addr: address, amount: u64): FungibleAsset 
    acquires DisTokenController {
        let controller = borrow_global<DisTokenController>(@disentry);
        primary_fungible_store::withdraw_with_ref(
            &controller.transfer_ref,
            user_addr,
            amount
        )
    }

    // === DFA HOOKS ===

    public fun on_withdraw<T: key>(
        store: Object<T>,
        amount: u64,
        transfer_ref: &TransferRef,
    ): FungibleAsset acquires VaultPosition, DisTokenController, ThermalEngine {
        let store_addr = object::object_address(&store);

        // Trigger thermal auto-compound before withdraw
        if (exists<VaultPosition>(store_addr)) {
            thermal_auto_compound_internal(borrow_global_mut<VaultPosition>(store_addr), store_addr);
        };

        fungible_asset::withdraw_with_ref(transfer_ref, store, amount)
    }

    public fun on_deposit<T: key>(
        store: Object<T>,
        fa: FungibleAsset,
        transfer_ref: &TransferRef,
    ) acquires VaultPosition, DisTokenController, ThermalEngine {
        let store_addr = object::object_address(&store);

        // Trigger thermal auto-compound before deposit
        if (exists<VaultPosition>(store_addr)) {
            thermal_auto_compound_internal(borrow_global_mut<VaultPosition>(store_addr), store_addr);
        };

        fungible_asset::deposit_with_ref(transfer_ref, store, fa);
    }

    public fun on_derived_balance<T: key>(
        store: Object<T>,
    ): u64 acquires VaultPosition, ThermalEngine {
        let store_addr = object::object_address(&store);
        let actual_balance = primary_fungible_store::balance(store_addr, get_metadata());

        if (!exists<VaultPosition>(store_addr)) {
            return actual_balance
        };

        let position = borrow_global<VaultPosition>(store_addr);
        let pending_rewards = calculate_thermal_pending_rewards(position);
        actual_balance + pending_rewards
    }

    // === INTERNAL FUNCTIONS ===

    /// Get token metadata object
    fun get_metadata(): Object<Metadata> {
        object::address_to_object<Metadata>(object::create_object_address(&@disentry, DIS_TOKEN_SYMBOL))
    }

    /// Auto-compound rewards using thermal engine
    fun thermal_auto_compound_internal(position: &mut VaultPosition, user_addr: address) 
    acquires DisTokenController, ThermalEngine {
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - position.last_compound_timestamp;

        if (time_elapsed > 0) {
            let pending_rewards = calculate_thermal_compound_rewards(position);

            if (pending_rewards >= MIN_COMPOUND_THRESHOLD) {
                let controller = borrow_global_mut<DisTokenController>(@disentry);
                let new_tokens = fungible_asset::mint(&controller.mint_ref, pending_rewards);
                
                primary_fungible_store::deposit_with_ref(
                    &controller.transfer_ref,
                    user_addr, 
                    new_tokens
                );
                
                position.token_amount += pending_rewards;
                position.total_rewards_earned += pending_rewards;
                position.last_compound_timestamp = current_time;
                
                update_thermal_pool_activity_efficient(position.thermal_pool_id, pending_rewards);
                
                controller.total_supply += pending_rewards;
                controller.total_rewards_distributed += pending_rewards;
            } else {
                position.last_compound_timestamp = current_time;
            };
        };
    }
    
    /// Calculate rewards using thermal engine
    fun calculate_thermal_compound_rewards(position: &VaultPosition): u64 acquires ThermalEngine {
        if (!exists<ThermalEngine>(@disentry)) {
            return calculate_compound_rewards(
                position.token_amount,
                timestamp::now_seconds() - position.last_compound_timestamp
            )
        };

        let thermal_engine = borrow_global<ThermalEngine>(@disentry);
        let pool = thermal_engine.pools.borrow(position.thermal_pool_id);
        
        let thermal_apy = calculate_thermal_apy(pool, thermal_engine.equilibrium_temperature);
        
        let time_elapsed = timestamp::now_seconds() - position.last_compound_timestamp;
        let annual_reward = (position.token_amount * thermal_apy) / 10000;
        (annual_reward * time_elapsed) / SECONDS_PER_YEAR
    }

    /// Calculate pending rewards using thermal engine
    fun calculate_thermal_pending_rewards(position: &VaultPosition): u64 acquires ThermalEngine {
        let current_time = timestamp::now_seconds();
        let time_elapsed = current_time - position.last_compound_timestamp;

        if (!exists<ThermalEngine>(@disentry) || time_elapsed == 0) {
            return calculate_compound_rewards(position.token_amount, time_elapsed)
        };

        calculate_thermal_compound_rewards(position)
    }

    fun update_thermal_pool_activity_efficient(pool_id: u64, amount: u64) acquires ThermalEngine {
       if (!exists<ThermalEngine>(@disentry)) return;
       
       let thermal_engine = borrow_global_mut<ThermalEngine>(@disentry);
       let pool = thermal_engine.pools.borrow_mut(pool_id);
       
       pool.last_activity_timestamp = timestamp::now_seconds();
       pool.cumulative_volume += amount;
       pool.pending_updates += 1;
    }

    fun update_thermal_pool_activity(pool_id: u64, amount: u64, is_new_user: bool) 
    acquires ThermalEngine {
        if (!exists<ThermalEngine>(@disentry)) return;
        
        let thermal_engine = borrow_global_mut<ThermalEngine>(@disentry);
        let pool = thermal_engine.pools.borrow_mut(pool_id);
        
        pool.last_activity_timestamp = timestamp::now_seconds();
        pool.cumulative_volume += amount;
        
        if (is_new_user) {
            pool.active_users += 1;
        };
        
        pool.last_temperature_update = 0;
    }

    fun assign_thermal_pool(user_addr: address): u64 acquires ThermalEngine {
        if (!exists<ThermalEngine>(@disentry)) return 0;
        
        let thermal_engine = borrow_global<ThermalEngine>(@disentry);
        let num_pools = thermal_engine.pools.length();
        
        address_to_u64(user_addr) % num_pools
    }

    // === VIEW FUNCTIONS ===
    
    #[view]
    public fun get_vault_position(user_addr: address): (u64, u64, u64, u64) acquires VaultPosition, ThermalEngine {
        if (!exists<VaultPosition>(user_addr)) {
            return (0, 0, 0, 0)
        };

        let position = borrow_global<VaultPosition>(user_addr);
        let pending_rewards = calculate_thermal_pending_rewards(position);
        
        (
            position.token_amount,
            position.total_rewards_earned,
            pending_rewards,
            position.deposit_timestamp
        )
    }

    #[view]
    public fun get_protocol_stats(): (u64, u64) acquires DisTokenController {
        let controller = borrow_global<DisTokenController>(@disentry);
        (controller.total_supply, controller.total_rewards_distributed)
    }

    #[view]
    public fun get_current_apy(): u64 {
        BASE_APY
    }

    #[view]
    public fun get_thermal_pool_info(pool_id: u64): (u64, u64, u64, u64, u64) acquires ThermalEngine {
        if (!exists<ThermalEngine>(@disentry)) {
            return (0, 0, 0, BASE_APY, BASE_TEMPERATURE)
        };
        
        let thermal_engine = borrow_global<ThermalEngine>(@disentry);
        if (pool_id >= thermal_engine.pools.length()) {
            return (0, 0, 0, BASE_APY, BASE_TEMPERATURE)
        };
        
        let pool = thermal_engine.pools.borrow(pool_id);
        let temperature = calculate_pool_temperature(pool);
        let apy = calculate_thermal_apy(pool, thermal_engine.equilibrium_temperature);
        
        (
            pool.total_liquidity,
            pool.active_users,
            pool.cumulative_volume,
            apy,
            temperature
        )
    }

    #[view]
    public fun get_user_thermal_info(user_addr: address): (u64, u64, u64) acquires VaultPosition, ThermalEngine {
        if (!exists<VaultPosition>(user_addr) || !exists<ThermalEngine>(@disentry)) {
            return (0, BASE_APY, BASE_TEMPERATURE)
        };
        
        let position = borrow_global<VaultPosition>(user_addr);
        let thermal_engine = borrow_global<ThermalEngine>(@disentry);
        let pool = thermal_engine.pools.borrow(position.thermal_pool_id);
        
        let temperature = calculate_pool_temperature(pool);
        let apy = calculate_thermal_apy(pool, thermal_engine.equilibrium_temperature);
        
        (position.thermal_pool_id, apy, temperature)
    }

    // === HELPER FUNCTIONS ===

    fun calculate_pool_temperature(pool: &ThermalPool): u64 {
        let current_time = timestamp::now_seconds();
        
        if (current_time - pool.last_temperature_update < 300) {
            return pool.temperature_cache
        };

        let base_temp = BASE_TEMPERATURE;
        
        let liquidity_factor = if (pool.total_liquidity > 100000000) {
            9900
        } else if (pool.total_liquidity > 10000000) {
            10000
        } else {
            10100
        };
        
        let time_since_activity = current_time - pool.last_activity_timestamp;
        let activity_boost = if (time_since_activity < 1800) {
            200
        } else if (time_since_activity < 7200) {
            100
        } else {
            0
        };
        
        let user_heat = if (pool.active_users > 0) {
            pool.active_users * 10
        } else {
            0
        };
        
        let pool_age_days = (current_time - pool.pool_creation_time) / 86400;
        let maturity_cooling = if (pool_age_days > 30) {
            50
        } else if (pool_age_days > 7) {
            25
        } else {
            0
        };
        
        let final_temp = (base_temp * liquidity_factor / 10000) + activity_boost + user_heat;
        if (final_temp > maturity_cooling) {
            final_temp - maturity_cooling
        } else {
            base_temp / 2
        }
    }

    fun calculate_thermal_apy(pool: &ThermalPool, equilibrium_temp: u64): u64 {
        let pool_temp = calculate_pool_temperature(pool);
        let base_apy = BASE_APY;
        
        let temp_factor = if (pool_temp > equilibrium_temp) {
            let deviation = pool_temp - equilibrium_temp;
            10000 + (deviation * 5)
        } else {
            let deviation = equilibrium_temp - pool_temp;
            let penalty = deviation * 3;
            if (penalty > 10000) {
                5000
            } else {
                10000 - penalty
            }
        };
        
        let equilibrium_distance = if (pool_temp > equilibrium_temp) {
            pool_temp - equilibrium_temp
        } else {
            equilibrium_temp - pool_temp
        };
        
        let equilibrium_bonus = if (equilibrium_distance < TEMPERATURE_PRECISION) {
            300
        } else if (equilibrium_distance < TEMPERATURE_PRECISION * 5) {
            150
        } else {
            0
        };
        
        let current_time = timestamp::now_seconds();
        let pool_age_days = (current_time - pool.pool_creation_time) / 86400;
        let maturity_bonus = if (pool_age_days > 30) {
            200
        } else if (pool_age_days > 7) {
            100
        } else {
            0
        };
        
        (base_apy * temp_factor / 10000) + equilibrium_bonus + maturity_bonus
    }

    fun calculate_compound_rewards(principal: u64, time_elapsed_seconds: u64): u64 {
        if (time_elapsed_seconds == 0 || principal == 0) {
            return 0
        };

        let annual_reward = (principal * BASE_APY) / 10000;
        (annual_reward * time_elapsed_seconds) / SECONDS_PER_YEAR
    }

    fun address_to_u64(addr: address): u64 {
        let addr_bytes = hash::sha2_256(bcs::to_bytes(&addr));
        let num = 0;
        let len = addr_bytes.length();
        let limit = if (len < 8) { len } else { 8 };
        let i = 0;
        while (i < limit) {
            num = (num << 8) | (addr_bytes[i] as u64);
            i += 1;
        };
        num
    }

    // === ADMIN FUNCTIONS ===

    public entry fun emergency_pause(admin: &signer) {
        assert!(signer::address_of(admin) == @disentry, E_NOT_AUTHORIZED);
    }

    // === TEST FUNCTIONS ===

    #[test_only]
    public fun initialize_for_test(admin: &signer) {
        init_module(admin);
    }

    #[test(admin = @disentry, user = @0x123)]
    public fun test_auto_compound(admin: &signer, user: &signer) 
    acquires DisTokenController, VaultPosition, ThermalEngine {
        let user_addr = signer::address_of(user);

        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(user_addr);
        timestamp::set_time_has_started_for_testing(&account::create_signer_for_test(@0x1));
        
        init_module(admin);

        deposit_liquidity(user, to_decimals(1, DECIMALS as u64));

        timestamp::fast_forward_seconds(31536000);
        
        let (amount_before, _, pending_before, _) = get_vault_position(user_addr);
        
        withdraw_liquidity(user, 1);
        
        let (amount_after, rewards_after, _, _) = get_vault_position(user_addr);
        assert!(rewards_after > 0, 4);
        assert!(amount_after > amount_before - to_decimals(1, DECIMALS as u64), 5);
    }

    #[test(admin = @disentry, user = @0x111)]
    public fun test_basic_flow(admin: &signer, user: &signer) 
    acquires DisTokenController, VaultPosition, ThermalEngine {
        let user_addr = signer::address_of(user);
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(user_addr);
        timestamp::set_time_has_started_for_testing(&account::create_signer_for_test(@0x1));

        init_module(admin);

        deposit_liquidity(user, to_decimals(200, DECIMALS as u64));

        let (balance, rewards, _, _) = get_vault_position(user_addr);
        assert!(balance == to_decimals(200, DECIMALS as u64), 1001);
        assert!(rewards == 0, 1002);

        debug::print(&timestamp::now_seconds());
        timestamp::fast_forward_seconds(31536000 / 2);
        debug::print(&timestamp::now_seconds());

        withdraw_liquidity(user, to_decimals(50, DECIMALS as u64));

        (balance, rewards, _, _) = get_vault_position(user_addr);
        debug::print(&string::utf8(b"Balance after withdraw: "));
        debug::print(&balance);
        debug::print(&string::utf8(b", Rewards: "));
        debug::print(&rewards);
        assert!(balance >= to_decimals(150, DECIMALS as u64), 2001);
        assert!(rewards > 0, 2002);

        timestamp::fast_forward_seconds(31536000);

        withdraw_liquidity(user, to_decimals(100, DECIMALS as u64));
    }
}