module disentry::hyperion_wrapper {
    use std::signer;
    use std::string::{Self, String};
    use std::option::{Self, Option};
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::bcs;
    use aptos_framework::fungible_asset::{Self, FungibleStore, FungibleAsset, Metadata, MintRef, TransferRef, BurnRef};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;

    use dex_contract::router_v3;
    use dex_contract::pool_v3::{Self, LiquidityPoolV3};
    use dex_contract::position_v3::{Self, Info};

    use disentry::core;

    // === ERROR CODES ===
    
    const E_NOT_AUTHORIZED: u64 = 1;
    const E_INSUFFICIENT_BALANCE: u64 = 2;
    const E_INVALID_AMOUNT: u64 = 3;
    const E_HYPERION_POOL_NOT_EXISTS: u64 = 6;
    const E_SLIPPAGE_TOO_HIGH: u64 = 7;

    // === HYPERION CONSTANTS ===

    const DEFAULT_SLIPPAGE_BPS: u64 = 300; // 3% slippage tolerance
    const MIN_LIQUIDITY_AMOUNT: u64 = 100000; // 0.001 tokens minimum
    const HYPERION_FEE_TIER: u8 = 3; // 0.3% fee tier
    const DEFAULT_SQRT_PRICE_LIMIT: u128 = 0; // No price limit
    const DEFAULT_TICK_LOWER: u32 = 0;
    const DEFAULT_TICK_UPPER: u32 = 100000;

   // === STORAGE STRUCTS ===

   /// Extended vault position for Hyperion integration
   struct HyperionVaultPosition has key {
       hyperion_position: Option<Object<position_v3::Info>>, // Position object on Hyperion V2
       backing_assets: vector<u64>,                          // Amounts of backing assets
       pending_fees: u64,                                    // Uncollected fees from Hyperion
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
       // Initialize token config with placeholder addresses
       // These should be updated with real addresses on mainnet
       let token_config = TokenConfig {
           apt_metadata: object::address_to_object<Metadata>(@0x1),
           usdc_metadata: object::address_to_object<Metadata>(@0x2), 
           usdt_metadata: object::address_to_object<Metadata>(@0x3),
           supported_tokens: vector::empty<Object<Metadata>>(),
       };
       
       move_to(admin, token_config);
   }

   // === HYPERION INTEGRATION FUNCTIONS ===

   /// Deposit liquidity using Hyperion V3 router
   public entry fun deposit_liquidity_hyperion(
       user: &signer,
       apt_amount: u64,
       usdc_amount: u64,
   ) acquires HyperionVaultPosition, TokenConfig {
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

       // 2. Add liquidity to the position
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
       
       // 3. Calculate dLP tokens to mint
       let dlp_amount = calculate_dlp_mint_amount(apt_amount, usdc_amount);
       
       // 4. Use core module to mint dLP tokens and create/update position
       let new_tokens = core::mint_dlp_tokens(dlp_amount);
       core::create_vault_position(user, dlp_amount);
       core::deposit_dlp_to_user(user_addr, new_tokens);
       
       // 5. Create or update Hyperion-specific position data
       if (!exists<HyperionVaultPosition>(user_addr)) {
           let backing_assets = vector::singleton(apt_amount);
           backing_assets.push_back(usdc_amount);
           
           let hyperion_position = HyperionVaultPosition {
               hyperion_position: option::some(lp),
               backing_assets,
               pending_fees: 0,
           };
           move_to(user, hyperion_position);
       } else {
           let hyperion_position = borrow_global_mut<HyperionVaultPosition>(user_addr);
           hyperion_position.hyperion_position = option::some(lp);
           
           // Update backing assets
           *hyperion_position.backing_assets.borrow_mut(0) += apt_amount;
           *hyperion_position.backing_assets.borrow_mut(1) += usdc_amount;
       };
   }

   /// Withdraw liquidity using Hyperion V3 router
   public entry fun withdraw_liquidity_hyperion(
       user: &signer,
       dlp_amount: u64,
       liquidity_delta: u128,
   ) acquires HyperionVaultPosition {
       let user_addr = signer::address_of(user);
       let hyperion_position = borrow_global_mut<HyperionVaultPosition>(user_addr);
       
       assert!(dlp_amount > 0, E_INVALID_AMOUNT);
       assert!(hyperion_position.hyperion_position.is_some(), E_HYPERION_POOL_NOT_EXISTS);
       
       let hyperion_position_obj = *hyperion_position.hyperion_position.borrow();
       let current_time = timestamp::now_seconds();
       let deadline = current_time + 600; // 10 minutes deadline
       
       // 1. Remove liquidity from Hyperion V3
       router_v3::remove_liquidity(
           user,
           hyperion_position_obj,
           liquidity_delta,
           0, // amount_a_min (accept any amount for simplicity)
           0, // amount_b_min  
           user_addr, // recipient
           deadline
       );
       
       // 2. Get dLP tokens from user's wallet
       let tokens_to_burn = core::withdraw_dlp_from_user(user_addr, dlp_amount);

       
       // 3. Update backing assets proportionally
       let (total_tokens, _, _, _) = core::get_vault_position(user_addr);
       let withdraw_ratio = (dlp_amount * 10000) / total_tokens;
       let apt_to_subtract = (hyperion_position.backing_assets[0] * withdraw_ratio) / 10000;
       let usdc_to_subtract = (hyperion_position.backing_assets[1] * withdraw_ratio) / 10000;
       
       *hyperion_position.backing_assets.borrow_mut(0) -= apt_to_subtract;
       *hyperion_position.backing_assets.borrow_mut(1) -= usdc_to_subtract;
       
       // 4. Update core position and burn tokens
       core::update_vault_position(user_addr, dlp_amount, false);
       core::burn_dlp_tokens(tokens_to_burn);
   }

   /// Harvest trading fees and rewards from Hyperion V3
   public entry fun harvest_hyperion_rewards(
       user: &signer
   ) acquires HyperionVaultPosition {
       let user_addr = signer::address_of(user);
       let hyperion_position = borrow_global_mut<HyperionVaultPosition>(user_addr);
       
       if (hyperion_position.hyperion_position.is_some()) {
           let hyperion_position_obj = *hyperion_position.hyperion_position.borrow();
           let position_addresses = vector::singleton(object::object_address(&hyperion_position_obj));
           
           // Claim fees using router_v3
           router_v3::claim_fees(user, position_addresses, user_addr);
           
           // Claim rewards using router_v3  
           router_v3::claim_rewards(user, hyperion_position_obj, user_addr);
           
           // Update pending fees (in a real implementation, you'd calculate the actual fees claimed)
           hyperion_position.pending_fees = 0;
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

   // === VIEW FUNCTIONS ===

   /// Get user's Hyperion position details
   /// @returns (has_position, apt_amount, usdc_amount, pending_fees)
   #[view]
   public fun get_hyperion_position(user_addr: address): (bool, u64, u64, u64) acquires HyperionVaultPosition {
       if (!exists<HyperionVaultPosition>(user_addr)) {
           return (false, 0, 0, 0)
       };

       let hyperion_position = borrow_global<HyperionVaultPosition>(user_addr);
       let has_position = hyperion_position.hyperion_position.is_some();
       let apt_amount = if (hyperion_position.backing_assets.length() > 0) {
           hyperion_position.backing_assets[0]
       } else {
           0
       };
       let usdc_amount = if (hyperion_position.backing_assets.length() > 1) {
           hyperion_position.backing_assets[1]
       } else {
           0
       };
       
       (has_position, apt_amount, usdc_amount, hyperion_position.pending_fees)
   }

   /// Get combined position info (core + hyperion)
   /// @returns (dlp_amount, total_rewards, pending_rewards, apt_amount, usdc_amount, pending_fees)
   #[view]
   public fun get_combined_position(user_addr: address): (u64, u64, u64, u64, u64, u64) acquires HyperionVaultPosition {
       // Get core position
       let (dlp_amount, total_rewards, pending_rewards, _) = core::get_vault_position(user_addr);
       
       // Get Hyperion position
       let (_, apt_amount, usdc_amount, pending_fees) = get_hyperion_position(user_addr);
       
       (dlp_amount, total_rewards, pending_rewards, apt_amount, usdc_amount, pending_fees)
   }

   // === HELPER FUNCTIONS ===

   fun calculate_dlp_mint_amount(apt_amount: u64, usdc_amount: u64): u64 {
       // Simple calculation: convert both assets to USD value and mint dLP accordingly
       // Assume 1 APT = $10 USD, 1 USDC = $1 USD (this should be replaced with oracle pricing)
       let apt_value = apt_amount * 10 * 100000000 / 100000000; // APT has 8 decimals
       let usdc_value = usdc_amount;
       
       apt_value + usdc_value // Total USD value becomes dLP amount
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

   /// Update Hyperion pool configuration
   public entry fun update_pool_config(
       admin: &signer,
       apt_usdc_pool_addr: address,
       apt_usdt_pool_addr: address,
       usdc_usdt_pool_addr: address,
   ) acquires HyperionPoolConfig {
       assert!(signer::address_of(admin) == @disentry, E_NOT_AUTHORIZED);
       
       let apt_usdc_pool = object::address_to_object<LiquidityPoolV3>(apt_usdc_pool_addr);
       let apt_usdt_pool = object::address_to_object<LiquidityPoolV3>(apt_usdt_pool_addr);
       let usdc_usdt_pool = object::address_to_object<LiquidityPoolV3>(usdc_usdt_pool_addr);
       
       if (!exists<HyperionPoolConfig>(@disentry)) {
           let pool_config = HyperionPoolConfig {
               apt_usdc_pool,
               apt_usdt_pool,
               usdc_usdt_pool,
               fee_tiers: vector::singleton(HYPERION_FEE_TIER),
               tick_lower: DEFAULT_TICK_LOWER,
               tick_upper: DEFAULT_TICK_UPPER,
           };
           move_to(admin, pool_config);
       } else {
           let pool_config = borrow_global_mut<HyperionPoolConfig>(@disentry);
           pool_config.apt_usdc_pool = apt_usdc_pool;
           pool_config.apt_usdt_pool = apt_usdt_pool;
           pool_config.usdc_usdt_pool = usdc_usdt_pool;
       };
   }

   // === TEST FUNCTIONS ===

   #[test_only]
   public fun initialize_for_test(admin: &signer) {
       init_module(admin);
   }
}