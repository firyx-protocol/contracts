module disentry::core {
    use std::signer;
    use std::string::{Self, String};
    use std::option::{Self, Option};
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::bcs;
    use aptos_framework::fungible_asset::{Self, FungibleStore, FungibleAsset, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::function_info;
    use aptos_framework::timestamp;
    use aptos_framework::hash;
    use aptos_framework::debug;

    use dex_contract::router_v3;
    use dex_contract::pool_v3::{Self, LiquidityPoolV3};
    use dex_contract::position_v3::{Self, Info};

    use disentry::math::{to_decimals, from_decimals};

    // === ERROR CODES ===
    
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 3;
    const E_COMPOUND_TOO_SMALL: u64 = 4;
    const E_THERMAL_ENGINE_NOT_INITIALIZED: u64 = 5;
    const E_HYPERION_POOL_NOT_EXISTS: u64 = 6;
    const E_SLIPPAGE_TOO_HIGH: u64 = 7;

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

    // === HYPERION CONSTANTS ===

    const DEFAULT_SLIPPAGE_BPS: u64 = 300; // 3% slippage tolerance
    const MIN_LIQUIDITY_AMOUNT: u64 = 100000; // 0.001 tokens minimum
    const HYPERION_FEE_TIER: u8 = 3; // 0.3% fee tier
    const DEFAULT_SQRT_PRICE_LIMIT: u128 = 0; // No price limit
    const DEFAULT_TICK_LOWER: u32 = 0;
    const DEFAULT_TICK_UPPER: u32 = 100000;

    // === STORAGE STRUCTS ===

    /// Stores token controller references and global statistics
    struct DisTokenController has key {
        mint_ref: MintRef,
        transfer_ref: TransferRef,
        burn_ref: BurnRef,
        total_supply: u64,
        total_rewards_distributed: u64,
        hyperion_pools: vector<Object<LiquidityPoolV3>>, // Pool objects on Hyperion V2
        backing_asset_types: vector<String>,              // APT, USDC, etc.
    }

    /// User's vault position including stake amount and rewards data
    struct VaultPosition has key {
        token_amount: u64,
        last_compound_timestamp: u64,
        total_rewards_earned: u64,
        deposit_timestamp: u64,
        thermal_pool_id: u64, // Which thermal pool user belongs to
        hyperion_position: Option<Object<position_v3::Info>>, // Position object on Hyperion V2
        backing_assets: vector<u64>,                          // Amounts of backing assets
        pending_fees: u64,                                    // Uncollected fees from Hyperion
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
        update_cooldown: u64,        // Cooldown period for updates
        pending_updates: u64,         // Pending updates to apply
    }

    /// System-wide thermal engine configuration
    struct ThermalEngine has key {
        pools: vector<ThermalPool>,
        equilibrium_temperature: u64,  // Target temperature for all pools
        last_equilibration_time: u64,  // When pools were last balanced
        equilibration_interval: u64,   // How often to run equilibration (3600s = 1h)
        total_system_energy: u64,      // Total energy in all pools
    }

    struct HyperionPoolConfig has key {
        apt_usdc_pool: Object<LiquidityPoolV3>,    // Main APT/USDC pool object
        apt_usdt_pool: Object<LiquidityPoolV3>,    // APT/USDT pool object
        usdc_usdt_pool: Object<LiquidityPoolV3>,   // Stablecoin pool object
        fee_tiers: vector<u8>,                     // Fee tiers for each pool
        tick_lower: u32,                           // Lower tick for positions
        tick_upper: u32,                           // Upper tick for positions
    }

    struct TokenConfig has key {
        apt_metadata: Object<Metadata>,
        usdc_metadata: Object<Metadata>,
        usdt_metadata: Object<Metadata>,
        supported_tokens: vector<Object<Metadata>>,
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
            hyperion_pools: vector::empty<Object<LiquidityPoolV3>>(),
            backing_asset_types: vector::empty<String>(),
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

    /// Deposit liquidity into the protocol
    public entry fun deposit_liquidity(
        user: &signer,
        amount: u64,
    ) acquires DisTokenController, VaultPosition, ThermalEngine {
        // Legacy function - just mint dLP directly (for testing)
        let user_addr = signer::address_of(user);
        
        let controller = borrow_global_mut<DisTokenController>(@disentry);
        let new_tokens = fungible_asset::mint(&controller.mint_ref, amount);
        
        if (!exists<VaultPosition>(user_addr)) {
            let thermal_pool_id = assign_thermal_pool(user_addr);
            let backing_assets = vector::singleton(amount);
            backing_assets.push_back(0u64);
            let position = VaultPosition {
                token_amount: amount,
                last_compound_timestamp: timestamp::now_seconds(),
                total_rewards_earned: 0,
                deposit_timestamp: timestamp::now_seconds(),
                thermal_pool_id,
                hyperion_position: option::none(),
                backing_assets,
                pending_fees: 0,
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

    /// Deposit liquidity using Hyperion V3 router
    public entry fun deposit_liquidity_hyperion(
        user: &signer,
        apt_amount: u64,
        usdc_amount: u64,
    ) acquires DisTokenController, VaultPosition, ThermalEngine, TokenConfig {
        let user_addr = signer::address_of(user);
        
        assert!(apt_amount > MIN_LIQUIDITY_AMOUNT, E_INVALID_AMOUNT);
        assert!(usdc_amount > MIN_LIQUIDITY_AMOUNT, E_INVALID_AMOUNT);
        
        let token_config = borrow_global<TokenConfig>(@disentry);
        let current_time = timestamp::now_seconds();
        let deadline = current_time + 600; // 10 minutes deadline

        // 1. Open position using router_v3
        let lp = pool_v3::open_position(
            user,
            token_config.apt_metadata,
            token_config.usdc_metadata,
            HYPERION_FEE_TIER,
            DEFAULT_TICK_LOWER,
            DEFAULT_TICK_UPPER,
        );

        // 3. Add liquidity to the position
        router_v3::add_liquidity(
            user,
            lp,
            token_config.apt_metadata,
            token_config.usdc_metadata,
            HYPERION_FEE_TIER,
            apt_amount,
            usdc_amount,
            (apt_amount * 95) / 100, // 5% slippage tolerance
            (usdc_amount * 95) / 100,
            deadline
        );
        
        // 4. Calculate dLP tokens to mint
        let dlp_amount = calculate_dlp_mint_amount(apt_amount, usdc_amount);
        
        // 5. Mint dLP tokens to user
        let controller = borrow_global_mut<DisTokenController>(@disentry);
        let new_tokens = fungible_asset::mint(&controller.mint_ref, dlp_amount);
        
        // 6. Create or update user position
        if (!exists<VaultPosition>(user_addr)) {
            let thermal_pool_id = assign_thermal_pool(user_addr);
            let backing_assets = vector::singleton(apt_amount);
            backing_assets.push_back(usdc_amount);
            
            let vault_position = VaultPosition {
                token_amount: dlp_amount,
                last_compound_timestamp: timestamp::now_seconds(),
                total_rewards_earned: 0,
                deposit_timestamp: timestamp::now_seconds(),
                thermal_pool_id,
                hyperion_position: option::some(lp),
                backing_assets,
                pending_fees: 0,
            };
            move_to(user, vault_position);
            
            update_thermal_pool_activity_efficient(thermal_pool_id, dlp_amount);
        } else {
            let vault_position = borrow_global_mut<VaultPosition>(user_addr);
            vault_position.token_amount += dlp_amount;
            vault_position.hyperion_position = option::some(lp);
            
            // Update backing assets
            *vault_position.backing_assets.borrow_mut(0) += apt_amount;
            *vault_position.backing_assets.borrow_mut(1) += usdc_amount;
            
            update_thermal_pool_activity_efficient(vault_position.thermal_pool_id, dlp_amount);
        };

        // 7. Deposit dLP tokens to user's wallet
        primary_fungible_store::deposit_with_ref(
            &controller.transfer_ref,
            user_addr, 
            new_tokens
        );
        
        controller.total_supply += dlp_amount;
    }

    /// Withdraw liquidity using Hyperion V3 router
    public entry fun withdraw_liquidity_hyperion(
        user: &signer,
        dlp_amount: u64,
        liquidity_delta: u128,
    ) acquires DisTokenController, VaultPosition, ThermalEngine {
        let user_addr = signer::address_of(user);
        let position = borrow_global_mut<VaultPosition>(user_addr);
        
        // Trigger thermal auto-compound first
        thermal_auto_compound_internal(position, user_addr);
        
        assert!(position.token_amount >= dlp_amount, E_INSUFFICIENT_BALANCE);
        assert!(dlp_amount > 0, E_INVALID_AMOUNT);
        assert!(position.hyperion_position.is_some(), E_HYPERION_POOL_NOT_EXISTS);
        
        let hyperion_position = *position.hyperion_position.borrow();
        let current_time = timestamp::now_seconds();
        let deadline = current_time + 600; // 10 minutes deadline
        
        // 1. Remove liquidity from Hyperion V3
        router_v3::remove_liquidity(
            user,
            hyperion_position,
            liquidity_delta,
            0, // amount_a_min (accept any amount for simplicity)
            0, // amount_b_min  
            user_addr, // recipient
            deadline
        );
        
        // 2. Burn dLP tokens
        let controller = borrow_global_mut<DisTokenController>(@disentry);
        let tokens_to_burn = primary_fungible_store::withdraw_with_ref(
            &controller.transfer_ref,
            user_addr,
            dlp_amount
        );
        
        // 3. Update position
        position.token_amount -= dlp_amount;
        
        // Update backing assets proportionally
        let withdraw_ratio = (dlp_amount * 10000) / (position.token_amount + dlp_amount);
        let apt_to_subtract = (position.backing_assets[0] * withdraw_ratio) / 10000;
        let usdc_to_subtract = (position.backing_assets[1] * withdraw_ratio) / 10000;
        
        *position.backing_assets.borrow_mut(0) -= apt_to_subtract;
        *position.backing_assets.borrow_mut(1) -= usdc_to_subtract;
        
        update_thermal_pool_activity_efficient(position.thermal_pool_id, dlp_amount);
        
        // 4. Burn the dLP tokens
        fungible_asset::burn(&controller.burn_ref, tokens_to_burn);
        controller.total_supply -= dlp_amount;
    }

    /// Harvest trading fees and rewards from Hyperion V3
    public entry fun harvest_hyperion_rewards(
        user: &signer
    ) acquires VaultPosition, DisTokenController, ThermalEngine {
        let user_addr = signer::address_of(user);
        let position = borrow_global_mut<VaultPosition>(user_addr);
        
        if (position.hyperion_position.is_some()) {
            let hyperion_position = *position.hyperion_position.borrow();
            let position_addresses = vector::singleton(object::object_address(&hyperion_position));
            
            // Claim fees using router_v3
            router_v3::claim_fees(user, position_addresses, user_addr);
            
            // Claim rewards using router_v3  
            router_v3::claim_rewards(user, hyperion_position, user_addr);
            
            // Update position - fees are now in user's account
            // For simplicity, we'll just trigger thermal compound
            thermal_auto_compound_internal(position, user_addr);
        };
    }

    /// Swap tokens using Hyperion V3 router
    public entry fun swap_tokens_hyperion(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        is_apt_to_usdc: bool,
    ) acquires TokenConfig {
        let token_config = borrow_global<TokenConfig>(@disentry);
        let user_addr = signer::address_of(user);
        let current_time = timestamp::now_seconds();
        let deadline = current_time + 300; // 5 minutes deadline
        
        if (is_apt_to_usdc) {
            // Swap APT to USDC
            router_v3::exact_input_swap_entry(
                user,
                HYPERION_FEE_TIER,
                amount_in,
                amount_out_min,
                DEFAULT_SQRT_PRICE_LIMIT,
                token_config.apt_metadata,
                token_config.usdc_metadata,
                user_addr,
                deadline
            );
        } else {
            // Swap USDC to APT
            router_v3::exact_input_swap_entry(
                user,
                HYPERION_FEE_TIER,
                amount_in,
                amount_out_min,
                DEFAULT_SQRT_PRICE_LIMIT,
                token_config.usdc_metadata,
                token_config.apt_metadata,
                user_addr,
                deadline
            );
        };
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
        actual_balance + pending_rewards + position.pending_fees
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
            // Fallback to simple calculation if thermal engine not initialized
            return calculate_compound_rewards(
                position.token_amount,
                timestamp::now_seconds() - position.last_compound_timestamp
            )
        };

        let thermal_engine = borrow_global<ThermalEngine>(@disentry);
        let pool = thermal_engine.pools.borrow(position.thermal_pool_id);
        
        // Calculate dynamic APY based on thermal state
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
        
        // Invalidate temperature cache
        pool.last_temperature_update = 0;
    }

    fun assign_thermal_pool(user_addr: address): u64 acquires ThermalEngine {
        if (!exists<ThermalEngine>(@disentry)) return 0;
        
        let thermal_engine = borrow_global<ThermalEngine>(@disentry);
        let num_pools = thermal_engine.pools.length();
        
        address_to_u64(user_addr) % num_pools
    }

    // === VIEW FUNCTIONS ===
    
    /// Get user vault position details
    /// @returns (token_amount, total_rewards_earned, pending_rewards, deposit_timestamp)
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

    /// Get protocol-wide statistics
    /// @returns (total_supply, total_rewards_distributed)
    #[view]
    public fun get_protocol_stats(): (u64, u64) acquires DisTokenController {
        let controller = borrow_global<DisTokenController>(@disentry);
        (controller.total_supply, controller.total_rewards_distributed)
    }

    /// Get current base APY
    #[view]
    public fun get_current_apy(): u64 {
        BASE_APY
    }

    /// Get information about a specific thermal pool
    /// @returns (total_liquidity, active_users, cumulative_volume, current_apy, temperature)
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

    /// Get thermal information for a specific user
    /// @returns (pool_id, current_apy, temperature)
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

    /// Calculate the temperature of a thermal pool
    fun calculate_pool_temperature(pool: &ThermalPool): u64 {
        let current_time = timestamp::now_seconds();
        
        // Cache temperature for 5 minutes to save gas
        if (current_time - pool.last_temperature_update < 300) {
            return pool.temperature_cache
        };

        let base_temp = BASE_TEMPERATURE;
        
        // 1. Liquidity factor: larger pools = more stable (lower temp variance)
        let liquidity_factor = if (pool.total_liquidity > 100000000) { // > 1000 tokens
            9900 // 99% - large pools more stable
        } else if (pool.total_liquidity > 10000000) { // > 100 tokens
            10000 // 100% - medium pools
        } else {
            10100 // 101% - small pools more volatile
        };
        
        // 2. Activity factor: recent activity = higher temperature
        let time_since_activity = current_time - pool.last_activity_timestamp;
        let activity_boost = if (time_since_activity < 1800) { // < 30 min
            200 // +2°C for recent activity
        } else if (time_since_activity < 7200) { // < 2 hours
            100 // +1°C for moderate activity
        } else {
            0 // Cold pool
        };
        
        // 3. User density: more active users = higher temperature
        let user_heat = if (pool.active_users > 0) {
            pool.active_users * 10 // 0.1°C per active user
        } else {
            0
        };
        
        // 4. Age factor: older pools = more stable (lower temperature)
        let pool_age_days = (current_time - pool.pool_creation_time) / 86400;
        let maturity_cooling = if (pool_age_days > 30) {
            50 // -0.5°C for mature pools
        } else if (pool_age_days > 7) {
            25 // -0.25°C for week-old pools
        } else {
            0
        };
        
        let final_temp = (base_temp * liquidity_factor / 10000) + activity_boost + user_heat;
        if (final_temp > maturity_cooling) {
            final_temp - maturity_cooling
        } else {
            base_temp / 2 // Minimum temperature
        }
    }

    /// Calculate dynamic APY based on thermal state
    fun calculate_thermal_apy(pool: &ThermalPool, equilibrium_temp: u64): u64 {
        let pool_temp = calculate_pool_temperature(pool);
        let base_apy = BASE_APY;
        
        // 1. Temperature deviation bonus/penalty
        let temp_factor = if (pool_temp > equilibrium_temp) {
            // Hot pool: higher activity = higher yield
            let deviation = pool_temp - equilibrium_temp;
            10000 + (deviation * 5) // +0.05% per degree above equilibrium
        } else {
            // Cold pool: lower activity = lower yield
            let deviation = equilibrium_temp - pool_temp;
            let penalty = deviation * 3; // -0.03% per degree below
            if (penalty > 10000) {
                5000 // Minimum 50% of base APY
            } else {
                10000 - penalty
            }
        };
        
        // 2. Equilibrium proximity bonus
        let equilibrium_distance = if (pool_temp > equilibrium_temp) {
            pool_temp - equilibrium_temp
        } else {
            equilibrium_temp - pool_temp
        };
        
        let equilibrium_bonus = if (equilibrium_distance < TEMPERATURE_PRECISION) { // Within 1°C
            300 // +3% bonus for being near equilibrium
        } else if (equilibrium_distance < TEMPERATURE_PRECISION * 5) { // Within 5°C
            150 // +1.5% bonus
        } else {
            0
        };
        
        // 3. Pool maturity bonus
        let current_time = timestamp::now_seconds();
        let pool_age_days = (current_time - pool.pool_creation_time) / 86400;
        let maturity_bonus = if (pool_age_days > 30) {
            200 // +2% for mature pools
        } else if (pool_age_days > 7) {
            100 // +1% for week-old pools
        } else {
            0
        };
        
        (base_apy * temp_factor / 10000) + equilibrium_bonus + maturity_bonus
    }

    fun calculate_dlp_mint_amount(apt_amount: u64, usdc_amount: u64): u64 {
        // Simple calculation: convert both assets to USD value and mint dLP accordingly
        // Assume 1 APT = $10 USD, 1 USDC = $1 USD
        let apt_value = apt_amount * 10 * 100000000 / 100000000; // APT has 8 decimals
        let usdc_value = usdc_amount;
        
        apt_value + usdc_value // Total USD value becomes dLP amount
    }

    /// Calculate rewards using standard APY calculation (fallback)
    fun calculate_compound_rewards(principal: u64, time_elapsed_seconds: u64): u64 {
        if (time_elapsed_seconds == 0 || principal == 0) {
            return 0
        };

        let annual_reward = (principal * BASE_APY) / 10000;
        (annual_reward * time_elapsed_seconds) / SECONDS_PER_YEAR
    }

    fun calculate_reward_value(reward_assets: vector<FungibleAsset>): u64 {
        let total_value = 0;
        let i = 0;
        while (i < reward_assets.length()) {
            let reward_fa = reward_assets.borrow(i);
            total_value += fungible_asset::amount(reward_fa);
            i += 1;
        };
        
        // Handle reward assets (deposit them to user)
        i = 0;
        while (i < reward_assets.length()) {
            let reward_fa = reward_assets.pop_back();
            if (fungible_asset::amount(&reward_fa) > 0) {
                // In a real implementation, you'd need to know the user address
                // For now, just destroy zero or handle appropriately
                fungible_asset::destroy_zero(reward_fa);
            } else {
                fungible_asset::destroy_zero(reward_fa);
            };
            i += 1;
        };
        
        reward_assets.destroy_empty();
        total_value
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

    /// Update token configuration for mainnet deployment
    public entry fun update_token_config(
        admin: &signer,
        apt_address: address,
        usdc_address: address,
        usdt_address: address,
    ) acquires TokenConfig {
        // Add admin authorization check here
        assert!(signer::address_of(admin) == @disentry, E_NOT_AUTHORIZED);
        
        let apt_metadata = object::address_to_object<Metadata>(apt_address);
        let usdc_metadata = object::address_to_object<Metadata>(usdc_address);
        let usdt_metadata = object::address_to_object<Metadata>(usdt_address);
        
        let token_config = borrow_global_mut<TokenConfig>(@disentry);
        token_config.apt_metadata = apt_metadata;
        token_config.usdc_metadata = usdc_metadata;
        token_config.usdt_metadata = usdt_metadata;
        
        // Update supported tokens list
        token_config.supported_tokens = vector::empty<Object<Metadata>>();
        token_config.supported_tokens.push_back(apt_metadata);
        token_config.supported_tokens.push_back(usdc_metadata);
        token_config.supported_tokens.push_back(usdt_metadata);
    }

    /// Emergency pause function
    public entry fun emergency_pause(admin: &signer) {
        assert!(signer::address_of(admin) == @disentry, E_NOT_AUTHORIZED);
        // Implement emergency pause logic here
        // This could disable deposits/withdrawals in emergency situations
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

        // (balance, rewards, _, _) = get_vault_position(user_addr);
        // assert!(balance == to_decimals(50, DECIMALS as u64), 3001);
        // assert!(rewards > 0, 3002);
    }
}