module firyx::loan_position {
    use aptos_framework::aptos_coin;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::signer;
    use aptos_framework::timestamp;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::primary_fungible_store::{Self};
    use aptos_framework::math64;
    use aptos_framework::math128;
    use aptos_framework::string;
    use aptos_framework::option;
    use aptos_framework::bcs;
    use aptos_framework::vector;
    use dex_contract::position_v3::Info;
    use dex_contract::router_v3;
    use dex_contract::pool_v3::{Self};
    use firyx::deposit_slot::{Self, DepositSlot};
    use firyx::loan_slot::{Self, LoanSlot};
    use firyx::math::{bps, precision};
    use firyx::events;

    // === CONSTANTS ===
    const BASE_RATE_BPS: u64 = 0; // 0%
    const BONUS_LIQUIDITY_BPS: u64 = 500; // 5%
    const DEFAULT_DEADLINE_TS: u64 = 0xffff_ffff_ffff_ffff;
    const RISK_FACTOR_BFS_VECTOR: vector<u64> = vector[5000, 10000, 15000, 20000]; // 50%, 100%, 150%, 200%
    const DURATION_YEAR_VECTOR_BPS: vector<u64> = vector[2500, 5000, 10000, 20000]; // 25%, 50%, 100%, 200%
    const MULTIPLIER_TERMS_ADJUSTMENT_BPS: vector<u64> = vector[800, 900, 1000, 1100, 1200]; // 80%, 90%, 100%, 110%, 120%

    // === ERRORS ===
    /// Loan position not found
    const E_LOAN_POSITION_NOT_FOUND: u64 = 1001;
    /// Unauthorized access to loan position
    const E_UNAUTHORIZED: u64 = 1002;
    /// Loan position is not active
    const E_NOT_ACTIVE: u64 = 1003;
    /// Invalid amount provided
    const E_INVALID_AMOUNT: u64 = 1004;
    /// Insufficient liquidity for operation
    const E_INSUFFICIENT_LIQUIDITY: u64 = 1005;
    /// Insufficient available borrow amount
    const E_INSUFFICIENT_AVAILABLE_BORROW: u64 = 1006;
    /// Invalid utilization rate
    const E_INVALID_UTILIZATION: u64 = 1007;
    /// Invalid risk factor index
    const E_INVALID_RISK_FACTOR: u64 = 1008;
    /// Invalid slope parameters
    const E_INVALID_SLOPE_PARAMETERS: u64 = 1009;
    /// Invalid kink utilization parameter
    const E_INVALID_KINK_UTILIZATION: u64 = 1010;
    /// Position already exists
    const E_POSITION_ALREADY_EXISTS: u64 = 1011;
    /// Cannot borrow more than available
    const E_BORROW_EXCEEDS_AVAILABLE: u64 = 1012;
    /// Invalid debt index
    const E_INVALID_DEBT_INDEX: u64 = 1013;
    /// Invalid token fee
    const E_INVALID_TOKEN_FEE: u64 = 1016;
    /// Invalid duration index
    const E_INVALID_DURATION_INDEX: u64 = 1017;
    /// Time elapsed must be greater than zero
    const E_INVALID_TIME_ELAPSED: u64 = 1018;
    /// Repayment failed
    const E_REPAYMENT_FAILED: u64 = 1019;
    /// Not owner
    const E_NOT_OWNER: u64 = 1020;

    struct LoanPositionParameters has copy, drop, store {
        // position parameters
        fee_tier: u8,
        tick_lower: u32,
        tick_upper: u32,

        // loan parameters
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64,
        risk_factor: u8, // risk factor index in RISK_FACTOR_BFS_VECTOR

        // additional parameters
        token_fee: Object<Metadata>
    }

    struct LoanPositionCap has drop, store {
        signer_cap: SignerCapability
    }

    struct LoanPosition has key {
        id: address,
        pos_object: Object<Info>,
        liquidity: u128,
        utilization: u64,
        current_debt_idx: u128,
        fee_growth_global_a: u128,
        fee_growth_global_b: u128,
        available_borrow: u64,
        total_borrowed: u64,
        parameters: LoanPositionParameters,
        lending_position_cap: LoanPositionCap,

        // Extended tracking
        active: bool,
        created_at_ts: u64,
        last_update_ts: u64,
        last_accrual_ts: u64,
        total_interest_earned: u128,
        active_loans_count: u64,
        total_share: u128
    }

    // Registry stores all loan position addresses and aggregate data
    struct LoanPositionRegistry has key {
        positions: vector<address>,
        total_liquidity: u128,
        total_active_loans: u64
    }

    // Initialize registry function, called when deploying or testing
    fun init_module(admin: &signer) {
        move_to(
            admin,
            LoanPositionRegistry {
                positions: vector::empty<address>(),
                total_liquidity: 0,
                total_active_loans: 0
            }
        );
    }

    public entry fun create_loan_position(
        creator: &signer,
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        token_fee: Object<Metadata>,
        fee_tier: u8,
        tick_lower: u32,
        tick_upper: u32,
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64,
        risk_factor: u8
    ) acquires LoanPositionRegistry {
        assert_is_valid_loan_position_parameters(
            slope_before_kink,
            slope_after_kink,
            kink_utilization,
            risk_factor
        );
        assert_token_fee(&token_fee, &token_a, &token_b);

        let _seed_vector = vector[
            bcs::to_bytes(&@firyx), bcs::to_bytes(&token_a), bcs::to_bytes(&token_b), bcs::to_bytes(
                &fee_tier
            ), bcs::to_bytes(&tick_lower), bcs::to_bytes(&tick_upper), bcs::to_bytes(
                &slope_before_kink
            ), bcs::to_bytes(&slope_after_kink), bcs::to_bytes(&kink_utilization), bcs::to_bytes(
                &risk_factor
            )
        ];

        let seed = bcs::to_bytes(&_seed_vector);
        let (signer_admin, cap_admin) = account::create_resource_account(creator, seed);
        let signer_addr = signer::address_of(creator);
        let constructor_ref = object::create_object(signer_addr);
        let container_signer = object::generate_signer(&constructor_ref);

        let pos_object =
            pool_v3::open_position(
                &signer_admin,
                token_a,
                token_b,
                fee_tier,
                tick_lower,
                tick_upper
            );

        move_to(
            &container_signer,
            LoanPosition {
                id: object::address_from_constructor_ref(&constructor_ref),
                pos_object,
                liquidity: 0,
                utilization: 0,
                current_debt_idx: precision(),
                fee_growth_global_a: 0,
                fee_growth_global_b: 0,
                available_borrow: 0,
                total_borrowed: 0,
                parameters: LoanPositionParameters {
                    fee_tier,
                    tick_lower,
                    tick_upper,
                    slope_before_kink,
                    slope_after_kink,
                    kink_utilization,
                    risk_factor,
                    token_fee
                },
                lending_position_cap: LoanPositionCap { signer_cap: cap_admin },
                active: true,
                created_at_ts: timestamp::now_seconds(),
                last_update_ts: timestamp::now_seconds(),
                last_accrual_ts: timestamp::now_seconds(),
                total_interest_earned: 0,
                active_loans_count: 0,
                total_share: 0
            }
        );

        let lending_position_object =
            object::object_from_constructor_ref<LoanPosition>(&constructor_ref);

        // Update registry
        let registry = borrow_global_mut<LoanPositionRegistry>(@firyx);
        registry.positions.push_back(object::object_address(&lending_position_object));

        events::emit_loan_position_created(
            object::object_address(&lending_position_object),
            token_a,
            token_b,
            token_fee,
            fee_tier,
            tick_lower,
            tick_upper,
            slope_before_kink,
            slope_after_kink,
            kink_utilization,
            risk_factor,
            timestamp::now_seconds()
        );
    }

    public entry fun deposit_liquidity(
        lender: &signer,
        position: Object<LoanPosition>,
        token_a: Object<Metadata>,
        token_b: Object<Metadata>,
        amount_a_desired: u64,
        amount_b_desired: u64,
        amount_a_min: u64,
        amount_b_min: u64
    ) acquires LoanPosition, LoanPositionRegistry {
        assert_valid_amount(amount_a_desired);
        assert_valid_amount(amount_b_desired);

        let pos = borrow_loan_position_mut(position);
        assert_position_active(pos);

        let (liquidity_minted, _, _) =
            router_v3::optimal_liquidity_amounts(
                pos.parameters.tick_lower,
                pos.parameters.tick_upper,
                token_a,
                token_b,
                pos.parameters.fee_tier,
                amount_a_desired,
                amount_b_desired,
                amount_a_min,
                amount_b_min
            );
        let amount = liquidity_minted;
        assert_valid_amount(amount as u64);

        let share = calculate_share_internal(pos, amount);
        pos.total_share += share;
        pos.liquidity += amount;
        pos.available_borrow = (pos.liquidity as u64) - pos.total_borrowed;
        pos.last_update_ts = timestamp::now_seconds();

        // Update registry total liquidity
        let registry = borrow_global_mut<LoanPositionRegistry>(@firyx);
        registry.total_liquidity += amount;

        let signer_admin =
            &account::create_signer_with_capability(&pos.lending_position_cap.signer_cap);

        let token_a = primary_fungible_store::withdraw(lender, token_a, amount_a_desired);
        let token_b = primary_fungible_store::withdraw(lender, token_b, amount_b_desired);
        let (remain_amount_token_a, remain_amount_token_b, remain_token_a, remain_token_b) =
            router_v3::add_liquidity_by_contract(
                signer_admin,
                pos.pos_object,
                amount_a_desired,
                amount_b_desired,
                amount_a_min,
                amount_b_min,
                token_a,
                token_b,
                DEFAULT_DEADLINE_TS
            );

        // Ensure claim fee and rewards
        ensure_claim_fee_and_rewards(pos);

        // Refund remaining tokens to lender
        if (remain_amount_token_a > 0) {
            primary_fungible_store::deposit(signer::address_of(lender), remain_token_a);
        } else {
            fungible_asset::destroy_zero(remain_token_a);
        };
        if (remain_amount_token_b > 0) {
            primary_fungible_store::deposit(signer::address_of(lender), remain_token_b);
        } else {
            fungible_asset::destroy_zero(remain_token_b);
        };

        let deposit_slot_obj =
            deposit_slot::create_deposit_slot(
                lender,
                object::object_address(&position),
                amount,
                share as u64,
                pos.fee_growth_global_a,
                pos.fee_growth_global_b
            );

        // Initialize fee growth debt for new deposit slot
        deposit_slot::update_fee_growth_debt(
            deposit_slot_obj,
            pos.fee_growth_global_a,
            pos.fee_growth_global_b
        );

        events::emit_liquidity_deposited(
            object::object_address(&position),
            signer::address_of(lender),
            object::object_address(&deposit_slot_obj),
            amount,
            share as u64,
            pos.liquidity,
            pos.total_share,
            pos.utilization,
            pos.last_update_ts
        );
    }

    public entry fun borrow_liquidity(
        borrower: &signer,
        position: Object<LoanPosition>,
        token_fee: Object<Metadata>,
        amount: u64,
        duration_idx: u8
    ) acquires LoanPosition, LoanPositionRegistry {
        assert_valid_amount(amount);
        assert_valid_duration_index(duration_idx);

        let pos = borrow_loan_position_mut(position);

        assert_position_active(pos);
        assert_token_fee_of_loan_position(pos, &token_fee);
        assert_sufficient_available_borrow(pos, amount);

        let reserve = calculate_reserve_internal(pos, amount as u128, duration_idx);
        let admin_signer =
            account::create_signer_with_capability(&pos.lending_position_cap.signer_cap);

        let reserve_fa = primary_fungible_store::withdraw(borrower, token_fee, reserve);
        // Transfer reserve from borrower to loan position
        primary_fungible_store::deposit(signer::address_of(&admin_signer), reserve_fa);

        // Update position state
        pos.available_borrow -= amount;
        pos.total_borrowed += amount;

        // Handle edge case when liquidity = 0
        pos.utilization =
            if (pos.liquidity > 0) {
                let util = (pos.total_borrowed * bps()) / (pos.liquidity as u64);
                if (util > bps()) { bps() }
                else { util }
            } else {
                assert!(pos.total_borrowed == 0, E_INVALID_UTILIZATION);
                0
            };
        pos.active_loans_count += 1;
        pos.last_update_ts = timestamp::now_seconds();

        // Update registry total active loans
        let registry = borrow_global_mut<LoanPositionRegistry>(@firyx);
        registry.total_active_loans += 1;

        let share = calculate_share_internal(pos, amount as u128);

        // Ensure claim fee and rewards
        ensure_claim_fee_and_rewards(pos);

        // Create loan slot for borrower
        let loan_slot_obj =
            loan_slot::create_loan_slot(
                borrower,
                object::object_address(&position),
                amount as u128,
                share,
                reserve,
                duration_idx,
                pos.current_debt_idx,
                pos.fee_growth_global_a,
                pos.fee_growth_global_b
            );

        // Initialize fee growth debt for new loan slot
        loan_slot::update_fee_growth_debt(
            loan_slot_obj,
            pos.fee_growth_global_a,
            pos.fee_growth_global_b
        );

        events::emit_liquidity_borrowed(
            object::object_address(&position),
            signer::address_of(borrower),
            object::object_address(&loan_slot_obj),
            amount,
            reserve,
            duration_idx,
            pos.current_debt_idx,
            pos.utilization,
            pos.total_borrowed,
            pos.available_borrow,
            pos.last_update_ts
        );
    }

    public entry fun loan_slot_claim_yield_and_repay(
        owner: &signer, position: Object<LoanPosition>, loan_slot: Object<LoanSlot>
    ) acquires LoanPosition, LoanPositionRegistry {
        assert_is_owner(loan_slot, signer::address_of(owner));

        let pos = borrow_loan_position_mut(position);
        assert_position_active(pos);

        // Ensure claim yield first
        ensure_claim_fee_and_rewards(pos);

        let share = loan_slot::share(loan_slot);

        if (share > 0) {
            let (
                yield_amount, amount_fee_asset_a, amount_fee_asset_b, reward_assets_count
            ) = loan_slot_claim_yield_internal(owner, pos, loan_slot);

            events::emit_yield_claimed(
                object::object_address(&position),
                signer::address_of(owner),
                object::object_address(&loan_slot),
                yield_amount,
                amount_fee_asset_a,
                amount_fee_asset_b,
                reward_assets_count,
                timestamp::now_seconds()
            );
        };

        let current_ts = timestamp::now_seconds();
        let time_elapsed = current_ts - pos.last_accrual_ts;
        assert_valid_time_elapsed(time_elapsed);

        let loan_slot_principal = loan_slot::principal(loan_slot);
        let debt_idx_at_borrow = loan_slot::debt_idx_at_borrow(loan_slot);

        let current_debt_idx = pos.current_debt_idx;
        let apr = calculate_apr_internal(pos, loan_slot_principal);
        let new_debt_idx = updated_debt_index(current_debt_idx, apr, time_elapsed);

        // Emit debt index update event
        events::emit_debt_index_updated(
            object::object_address(&position),
            current_debt_idx,
            new_debt_idx,
            apr,
            time_elapsed,
            current_ts
        );

        pos.current_debt_idx = new_debt_idx;
        pos.last_accrual_ts = current_ts;
        let amount_to_repay =
            math128::mul_div(
                loan_slot_principal,
                new_debt_idx,
                debt_idx_at_borrow
            ) as u64;

        let (principal_repaid, interest_repaid, loan_repaid, _) =
            loan_slot::repay(
                owner,
                loan_slot,
                pos.current_debt_idx,
                amount_to_repay
            );

        assert!(loan_repaid, E_REPAYMENT_FAILED);

        // Update position state
        pos.total_borrowed -= principal_repaid;
        pos.available_borrow += principal_repaid;
        pos.utilization =
            if (pos.liquidity > 0) {
                (pos.total_borrowed * bps()) / (pos.liquidity as u64)
            } else { 0 };

        pos.active_loans_count =
            if (pos.active_loans_count > 0) {
                pos.active_loans_count - 1
            } else { 0 };

        let registry = borrow_global_mut<LoanPositionRegistry>(@firyx);
        if (registry.total_active_loans > 0) {
            registry.total_active_loans -= 1;
        };

        pos.last_update_ts = current_ts;

        events::emit_loan_repaid(
            object::object_address(&loan_slot),
            signer::address_of(owner),
            principal_repaid + interest_repaid,
            principal_repaid,
            interest_repaid,
            loan_slot::principal(loan_slot),
            loan_repaid,
            pos.current_debt_idx,
            current_ts
        );
    }

    public entry fun deposit_slot_claim_yield(
        owner: &signer, position: Object<LoanPosition>, deposit_slot: Object<DepositSlot>
    ) acquires LoanPosition {
        assert_is_owner(deposit_slot, signer::address_of(owner));
        let pos = borrow_loan_position_mut(position);
        assert_position_active(pos);

        // Ensure claim yield first
        ensure_claim_fee_and_rewards(pos);
        
        let (yield_amount, amount_fee_asset_a, amount_fee_asset_b, reward_assets_count) =
            deposit_slot_claim_yield_internal(owner, pos, deposit_slot);

        events::emit_yield_claimed(
            object::object_address(&position),
            signer::address_of(owner),
            object::object_address(&deposit_slot),
            yield_amount,
            amount_fee_asset_a,
            amount_fee_asset_b,
            reward_assets_count,
            pos.last_update_ts
        );
    }

    fun deposit_slot_claim_yield_internal(
        owner: &signer, pos: &mut LoanPosition, deposit_slot: Object<DepositSlot>
    ): (u128, u64, u64, u64) {
        let admin_signer =
            account::create_signer_with_capability(&pos.lending_position_cap.signer_cap);
        let share = deposit_slot::share(deposit_slot);
        assert!(
            share > 0 && (share as u128) <= pos.total_share,
            E_INVALID_AMOUNT
        );

        let fee_debt_a = deposit_slot::fee_growth_debt_a(deposit_slot);
        let fee_debt_b = deposit_slot::fee_growth_debt_b(deposit_slot);

        let accumulated_fee_a =
            if (pos.fee_growth_global_a > fee_debt_a) {
                math128::mul_div(
                    pos.fee_growth_global_a - fee_debt_a,
                    share as u128,
                    precision()
                ) as u64
            } else { 0 };

        let accumulated_fee_b =
            if (pos.fee_growth_global_b > fee_debt_b) {
                math128::mul_div(
                    pos.fee_growth_global_b - fee_debt_b,
                    share as u128,
                    precision()
                ) as u64
            } else { 0 };

        let (fee_asset_a, fee_asset_b) =
            pool_v3::claim_fees(&admin_signer, pos.pos_object);

        accure_fee_growth_global(pos, accumulated_fee_a, accumulated_fee_b);

        let metadata_a = fungible_asset::metadata_from_asset(&fee_asset_a);
        let metadata_b = fungible_asset::metadata_from_asset(&fee_asset_b);

        primary_fungible_store::deposit(signer::address_of(&admin_signer), fee_asset_a);
        primary_fungible_store::deposit(signer::address_of(&admin_signer), fee_asset_b);

        deposit_slot::update_yield_earned(
            deposit_slot, accumulated_fee_a as u128, accumulated_fee_b as u128
        );

        if (accumulated_fee_a > 0) {
            let user_fee_a =
                primary_fungible_store::withdraw(
                    &admin_signer, metadata_a, accumulated_fee_a
                );
            primary_fungible_store::deposit(signer::address_of(owner), user_fee_a);
        };

        if (accumulated_fee_b > 0) {
            let user_fee_b =
                primary_fungible_store::withdraw(
                    &admin_signer, metadata_b, accumulated_fee_b
                );
            primary_fungible_store::deposit(signer::address_of(owner), user_fee_b);
        };

        let rewared_assets = pool_v3::claim_rewards(&admin_signer, pos.pos_object);
        let yield_amount = math128::mul_div(share as u128, pos.liquidity, pos.total_share);
        let ratio =
            if (pos.liquidity > 0) {
                math128::mul_div(yield_amount, precision(), pos.liquidity)
            } else { 0 };

        assert_valid_amount(yield_amount as u64);

        let reward_assets_count = rewared_assets.length();
        rewared_assets.for_each(
            |asset| {
                let amount_asset = fungible_asset::amount(&asset);
                if (amount_asset > 0) {
                    let yield_amount_asset =
                        math128::mul_div(amount_asset as u128, ratio, precision()) as u64;
                    if (yield_amount_asset > 0 && amount_asset >= yield_amount_asset) {
                        let yield_portion =
                            fungible_asset::extract(&mut asset, yield_amount_asset);
                        primary_fungible_store::deposit(
                            signer::address_of(owner), yield_portion
                        );
                    };
                };
                primary_fungible_store::deposit(signer::address_of(&admin_signer), asset);
            }
        );

        deposit_slot::update_fee_growth_debt(
            deposit_slot, pos.fee_growth_global_a, pos.fee_growth_global_b
        );
        pos.total_interest_earned += yield_amount;
        pos.last_update_ts = timestamp::now_seconds();

        (yield_amount, accumulated_fee_a, accumulated_fee_b, reward_assets_count)
    }

    fun loan_slot_claim_yield_internal(
        owner: &signer, pos: &mut LoanPosition, loan_slot: Object<LoanSlot>
    ): (u128, u64, u64, u64) {
        let admin_signer =
            account::create_signer_with_capability(&pos.lending_position_cap.signer_cap);
        let share = loan_slot::share(loan_slot);
        assert!(
            share > 0 && share <= pos.total_share,
            E_INVALID_AMOUNT
        );

        let fee_debt_a = loan_slot::fee_growth_debt_a(loan_slot);
        let fee_debt_b = loan_slot::fee_growth_debt_b(loan_slot);

        let accumulated_fee_a =
            if (pos.fee_growth_global_a > fee_debt_a) {
                math128::mul_div(pos.fee_growth_global_a - fee_debt_a, share, precision()) as u64
            } else { 0 };

        let accumulated_fee_b =
            if (pos.fee_growth_global_b > fee_debt_b) {
                math128::mul_div(pos.fee_growth_global_b - fee_debt_b, share, precision()) as u64
            } else { 0 };

        let (fee_asset_a, fee_asset_b) =
            pool_v3::claim_fees(&admin_signer, pos.pos_object);

        accure_fee_growth_global(pos, accumulated_fee_a, accumulated_fee_b);

        let metadata_a = fungible_asset::metadata_from_asset(&fee_asset_a);
        let metadata_b = fungible_asset::metadata_from_asset(&fee_asset_b);

        primary_fungible_store::deposit(signer::address_of(&admin_signer), fee_asset_a);
        primary_fungible_store::deposit(signer::address_of(&admin_signer), fee_asset_b);

        loan_slot::update_yield_earned(
            loan_slot, accumulated_fee_a as u128, accumulated_fee_b as u128
        );

        if (accumulated_fee_a > 0) {
            let user_fee_a =
                primary_fungible_store::withdraw(
                    &admin_signer, metadata_a, accumulated_fee_a
                );
            primary_fungible_store::deposit(signer::address_of(owner), user_fee_a);
        };

        if (accumulated_fee_b > 0) {
            let user_fee_b =
                primary_fungible_store::withdraw(
                    &admin_signer, metadata_b, accumulated_fee_b
                );
            primary_fungible_store::deposit(signer::address_of(owner), user_fee_b);
        };

        let rewared_assets = pool_v3::claim_rewards(&admin_signer, pos.pos_object);
        let yield_amount = math128::mul_div(share, pos.liquidity, pos.total_share);
        let ratio =
            if (pos.liquidity > 0) {
                math128::mul_div(yield_amount, precision(), pos.liquidity)
            } else { 0 };

        let reward_assets_count = rewared_assets.length();
        rewared_assets.for_each(
            |asset| {
                let amount_asset = fungible_asset::amount(&asset);
                if (amount_asset > 0) {
                    let yield_amount_asset =
                        math128::mul_div(amount_asset as u128, ratio, precision()) as u64;
                    if (yield_amount_asset > 0 && amount_asset >= yield_amount_asset) {
                        let yield_portion =
                            fungible_asset::extract(&mut asset, yield_amount_asset);
                        primary_fungible_store::deposit(
                            signer::address_of(owner), yield_portion
                        );
                    };
                };
                primary_fungible_store::deposit(signer::address_of(&admin_signer), asset);
            }
        );

        loan_slot::update_fee_growth_debt(
            loan_slot, pos.fee_growth_global_a, pos.fee_growth_global_b
        );
        pos.total_interest_earned += yield_amount;
        pos.last_update_ts = timestamp::now_seconds();

        (yield_amount, accumulated_fee_a, accumulated_fee_b, reward_assets_count)
    }

    public fun ensure_claim_fee_and_rewards(pos: &mut LoanPosition) {
        let admin_signer =
            account::create_signer_with_capability(&pos.lending_position_cap.signer_cap);
        let (fee_asset_a, fee_asset_b) =
            pool_v3::claim_fees(&admin_signer, pos.pos_object);
        accure_fee_growth_global(
            pos,
            fungible_asset::amount(&fee_asset_a),
            fungible_asset::amount(&fee_asset_b)
        );
        primary_fungible_store::deposit(signer::address_of(&admin_signer), fee_asset_a);
        primary_fungible_store::deposit(signer::address_of(&admin_signer), fee_asset_b);

        let rewared_assets = pool_v3::claim_rewards(&admin_signer, pos.pos_object);
        rewared_assets.for_each(|asset| {
            primary_fungible_store::deposit(signer::address_of(&admin_signer), asset);
        });

        pos.last_update_ts = timestamp::now_seconds();
    }

    fun accure_fee_growth_global(
        pos: &mut LoanPosition, fee_asset_a: u64, fee_asset_b: u64
    ) {

        if (fee_asset_a > 0 || fee_asset_b > 0) {
            let fee_growth_per_share_a =
                if (pos.total_share > 0) {
                    math128::mul_div(fee_asset_a as u128, precision(), pos.total_share)
                } else { 0 };
            let fee_growth_per_share_b =
                if (pos.total_share > 0) {
                    math128::mul_div(fee_asset_b as u128, precision(), pos.total_share)
                } else { 0 };

            pos.fee_growth_global_a += fee_growth_per_share_a;
            pos.fee_growth_global_b += fee_growth_per_share_b;
        };

        pos.last_update_ts = timestamp::now_seconds();
    }

    fun updated_debt_index(
        current_debt_idx: u128, apr: u64, time_elapsed: u64
    ): u128 {
        let seconds_per_year = 31_536_000; // 365 days

        let interest_rate_per_second =
            math128::mul_div(
                apr as u128,
                time_elapsed as u128,
                (bps() as u128) * (seconds_per_year as u128)
            );

        // Approximation: (1 + r) ≈ 1 + r for small r
        current_debt_idx
            + math128::mul_div(current_debt_idx, interest_rate_per_second, precision())
    }

    /// Calculate n^risk_power where risk_power is in bps
    /// Examples:
    /// - 5000 bps (0.5) => sqrt(n)
    /// - 10000 bps (1.0) => n
    /// - 15000 bps (1.5) => sqrt(n) * n
    /// - 20000 bps (2.0) => n^2
    fun calculate_power_bps(n: u64, risk_power_bps: u64): u64 {
        if (risk_power_bps == 5000) {
            // 0.5 power => sqrt(n)
            math64::sqrt(n)
        } else if (risk_power_bps == 10000) {
            // 1.0 power => n
            n
        } else if (risk_power_bps == 15000) {
            // 1.5 power => sqrt(n) * n
            math64::sqrt(n) * n
        } else if (risk_power_bps == 20000) {
            // 2.0 power => n^2
            n * n
        } else {
            // Default to linear for unsupported powers
            n
        }
    }

    fun calculate_apr_internal(pos: &LoanPosition, amount: u128): u64 {
        assert_valid_utilization(pos.utilization);
        let params = &pos.parameters;
        let utilization =
            math64::mul_div(
                (pos.total_borrowed as u64) + (amount as u64),
                bps(),
                pos.liquidity as u64
            );

        assert_valid_utilization(utilization);

        if (utilization < params.kink_utilization) {
            // U < U_optimal
            BASE_RATE_BPS
                + math64::mul_div(
                    params.slope_before_kink,
                    utilization,
                    params.kink_utilization
                )
        } else {
            // U >= U_optimal: Ensure smooth transition
            let base_rate = BASE_RATE_BPS + params.slope_before_kink;

            if (utilization == params.kink_utilization) {
                base_rate
            } else {
                let excess_util = utilization - params.kink_utilization;
                let max_excess = bps() - params.kink_utilization;
                let excess_ratio = math64::mul_div(excess_util, bps(), max_excess);

                let risk_factor_bps = RISK_FACTOR_BFS_VECTOR[(params.risk_factor as u64)];
                let power_term = calculate_power_bps(excess_ratio, risk_factor_bps);

                base_rate + math64::mul_div(params.slope_after_kink, power_term, bps())
            }
        }
    }

    fun calculate_share_internal(position: &LoanPosition, amount: u128): u128 {
        // First case - empty pool
        if (position.total_share == 0 && position.liquidity == 0) { amount }
        // Normal case
        else if (position.total_share > 0 && position.liquidity > 0) {
            math128::mul_div(amount, position.total_share, position.liquidity)
        }
        // Error case - should not happen
        else {
            abort E_INVALID_AMOUNT
        }
    }

    fun calculate_reserve_internal(
        pos: &LoanPosition, amount: u128, duration_idx: u8
    ): u64 {
        assert_valid_duration_index(duration_idx);

        let apr = calculate_apr_internal(pos, amount);
        let duration_year_bps = DURATION_YEAR_VECTOR_BPS[duration_idx as u64];
        let multiplier_terms_adjustment_bps =
            MULTIPLIER_TERMS_ADJUSTMENT_BPS[duration_idx as u64];
        let risk_factor_bps = RISK_FACTOR_BFS_VECTOR[pos.parameters.risk_factor as u64];

        // Simplified calculation to avoid precision loss
        // reserve = (amount * apr * duration_year_bps * risk_factor_bps * multiplier_terms_adjustment_bps) / (bps^4)
        let numerator =
            amount * (apr as u128) * (duration_year_bps as u128)
                * (risk_factor_bps as u128) * (multiplier_terms_adjustment_bps as u128);

        let denominator = (bps() as u128) * (bps() as u128) * (bps() as u128)
            * (bps() as u128); // bps^4

        let reserve = numerator / denominator;

        // Ensure minimum reserve for non-zero amounts
        if (reserve == 0 && amount > 0) {
            // Calculate minimum based on amount size
            let min_reserve =
                if (amount >= 1000000) { // >= 1M
                    amount / 10000 // 0.01% of amount
                } else if (amount >= 10000) { // >= 10K
                    amount / 1000 // 0.1% of amount
                } else {
                    1 // Minimum 1 unit
                };
            min_reserve as u64
        } else {
            reserve as u64
        }
    }

    #[view]
    public fun lending_position(position_addr: address): Object<LoanPosition> {
        object::address_to_object<LoanPosition>(position_addr)
    }

    // === VIEW FUNCTIONS FOR TRACKING ALL POSITIONS ===

    #[view]
    /// Get all loan position addresses
    public fun all_loan_position_addresses(): vector<address> acquires LoanPositionRegistry {
        let registry = borrow_global<LoanPositionRegistry>(@firyx);
        registry.positions
    }

    #[view]
    /// Get total number of loan positions
    public fun total_loan_positions(): u64 acquires LoanPositionRegistry {
        let registry = borrow_global<LoanPositionRegistry>(@firyx);
        registry.positions.length()
    }

    #[view]
    /// Get total liquidity across all positions
    public fun total_liquidity(): u128 acquires LoanPositionRegistry {
        let registry = borrow_global<LoanPositionRegistry>(@firyx);
        registry.total_liquidity
    }

    #[view]
    /// Get total active loans across all positions
    public fun total_active_loans(): u64 acquires LoanPositionRegistry {
        let registry = borrow_global<LoanPositionRegistry>(@firyx);
        registry.total_active_loans
    }

    #[view]
    public fun get_fee_growth_global(
        position: Object<LoanPosition>
    ): (u128, u128) acquires LoanPosition {
        let pos = borrow_loan_position(position);
        (pos.fee_growth_global_a, pos.fee_growth_global_b)
    }

    // === FEE GROWTH MANAGEMENT ===

    public(friend) fun update_fee_growth_global(
        position: Object<LoanPosition>, fee_growth_a: u128, fee_growth_b: u128
    ) acquires LoanPosition {
        let pos = borrow_loan_position_mut(position);
        pos.fee_growth_global_a += fee_growth_a;
        pos.fee_growth_global_b += fee_growth_b;
        pos.last_update_ts = timestamp::now_seconds();
    }

    #[view]
    public fun calculate_apr(pos_obj: Object<LoanPosition>, amount: u128): u64 acquires LoanPosition {
        let pos = borrow_loan_position(pos_obj);
        calculate_apr_internal(pos, amount)
    }

    #[view]
    public fun calculate_reserve(
        pos_obj: Object<LoanPosition>, amount: u128, duration_idx: u8
    ): u64 acquires LoanPosition {
        let pos = borrow_loan_position(pos_obj);
        calculate_reserve_internal(pos, amount, duration_idx)
    }

    #[view]
    public fun calculate_deposit_slot_yield(
        pos_obj: Object<LoanPosition>, deposit_slot: Object<DepositSlot>
    ): (u128, u64, u64, u64) acquires LoanPosition {
        let pos = borrow_loan_position(pos_obj);
        let share = deposit_slot::share(deposit_slot);

        if (share == 0 || pos.total_share == 0 || pos.liquidity == 0) {
            return (0, 0, 0, 0)
        };

        let yield_amount = math128::mul_div(share as u128, pos.liquidity, pos.total_share);
        let pending_fee = pool_v3::get_pending_fees(pos.pos_object);
        let pending_fee_a = pending_fee[0];
        let pending_fee_b = pending_fee[1];

        let simulated_fee_growth_a = pos.fee_growth_global_a;
        let simulated_fee_growth_b = pos.fee_growth_global_b;

        if (pos.total_share > 0) {
            if (pending_fee_a > 0) {
                simulated_fee_growth_a += math128::mul_div(
                    pending_fee_a as u128,
                    precision(),
                    pos.total_share
                );
            };
            if (pending_fee_b > 0) {
                simulated_fee_growth_b += math128::mul_div(
                    pending_fee_b as u128,
                    precision(),
                    pos.total_share
                );
            };
        };

        let fee_debt_a = deposit_slot::fee_growth_debt_a(deposit_slot);
        let fee_debt_b = deposit_slot::fee_growth_debt_b(deposit_slot);

        let total_fee_a =
            if (simulated_fee_growth_a > fee_debt_a) {
                math128::mul_div(
                    simulated_fee_growth_a - fee_debt_a,
                    share as u128,
                    precision()
                ) as u64
            } else { 0 };

        let total_fee_b =
            if (simulated_fee_growth_b > fee_debt_b) {
                math128::mul_div(
                    simulated_fee_growth_b - fee_debt_b,
                    share as u128,
                    precision()
                ) as u64
            } else { 0 };

        let pending_rewards = pool_v3::get_pending_rewards(pos.pos_object);
        let reward_assets_count = pending_rewards.length();

        (yield_amount, total_fee_a, total_fee_b, reward_assets_count)
    }

    #[view]
    public fun calculate_loan_slot_yield(
        pos_obj: Object<LoanPosition>, loan_slot: Object<LoanSlot>
    ): (u128, u64, u64, u64) acquires LoanPosition {
        let pos = borrow_loan_position(pos_obj);
        let share = loan_slot::share(loan_slot);

        if (share == 0 || pos.total_share == 0 || pos.liquidity == 0) {
            return (0, 0, 0, 0)
        };

        let yield_amount = math128::mul_div(share, pos.liquidity, pos.total_share);
        let pending_fee = pool_v3::get_pending_fees(pos.pos_object);
        let pending_fee_a = pending_fee[0];
        let pending_fee_b = pending_fee[1];

        let simulated_fee_growth_a = pos.fee_growth_global_a;
        let simulated_fee_growth_b = pos.fee_growth_global_b;

        if (pos.total_share > 0) {
            if (pending_fee_a > 0) {
                simulated_fee_growth_a += math128::mul_div(
                    pending_fee_a as u128,
                    precision(),
                    pos.total_share
                );
            };
            if (pending_fee_b > 0) {
                simulated_fee_growth_b += math128::mul_div(
                    pending_fee_b as u128,
                    precision(),
                    pos.total_share
                );
            };
        };

        let fee_debt_a = loan_slot::fee_growth_debt_a(loan_slot);
        let fee_debt_b = loan_slot::fee_growth_debt_b(loan_slot);

        let total_fee_a =
            if (simulated_fee_growth_a > fee_debt_a) {
                math128::mul_div(
                    simulated_fee_growth_a - fee_debt_a,
                    share,
                    precision()
                ) as u64
            } else { 0 };

        let total_fee_b =
            if (simulated_fee_growth_b > fee_debt_b) {
                math128::mul_div(
                    simulated_fee_growth_b - fee_debt_b,
                    share,
                    precision()
                ) as u64
            } else { 0 };

        let pending_rewards = pool_v3::get_pending_rewards(pos.pos_object);
        let reward_assets_count = pending_rewards.length();

        (yield_amount, total_fee_a, total_fee_b, reward_assets_count)
    }

    // === HELPER FUNCTIONS ===

    /// Validate owner
    fun assert_is_owner<T: key>(obj: Object<T>, owner: address) {
        assert!(object::is_owner(obj, owner), E_NOT_OWNER);
    }

    /// Validate loan position parameters
    fun assert_is_valid_loan_position_parameters(
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64,
        risk_factor: u8
    ) {
        assert!(slope_before_kink > 0, E_INVALID_SLOPE_PARAMETERS);
        assert!(slope_after_kink > 0, E_INVALID_SLOPE_PARAMETERS);
        assert!(
            kink_utilization > 0 && kink_utilization <= bps(),
            E_INVALID_KINK_UTILIZATION
        );
        assert!(
            (risk_factor as u64) < RISK_FACTOR_BFS_VECTOR.length(), E_INVALID_RISK_FACTOR
        );
    }

    /// Validate amount is greater than zero
    fun assert_valid_amount(amount: u64) {
        assert!(amount > 0, E_INVALID_AMOUNT);
    }

    /// Validate debt index is valid
    fun assert_valid_debt_index(debt_idx: u128) {
        assert!(debt_idx >= precision(), E_INVALID_DEBT_INDEX);
    }

    /// Validate duration index
    fun assert_valid_duration_index(duration_idx: u8) {
        assert!(
            (duration_idx as u64) < DURATION_YEAR_VECTOR_BPS.length(),
            E_INVALID_DURATION_INDEX
        );
    }

    /// Validate sufficient borrowable amount
    fun assert_sufficient_available_borrow(
        position: &LoanPosition, amount: u64
    ) {
        assert!(amount <= position.available_borrow, E_INSUFFICIENT_AVAILABLE_BORROW);
    }

    /// Validate time elapsed is positive
    fun assert_valid_time_elapsed(time_elapsed: u64) {
        assert!(time_elapsed > 0, E_INVALID_TIME_ELAPSED);
        let max_time_elapsed = 365 * 24 * 3600; // Maximum 1 year
        assert!(time_elapsed <= max_time_elapsed, E_INVALID_TIME_ELAPSED);
    }

    /// Validate utilization rate
    fun assert_valid_utilization(utilization: u64) {
        assert!(utilization <= bps(), E_INVALID_UTILIZATION);
    }

    fun assert_token_fee(
        token_fee: &Object<Metadata>,
        token_a: &Object<Metadata>,
        token_b: &Object<Metadata>
    ) {
        let addr_fee = object::object_address(token_fee);
        let addr_a = object::object_address(token_a);
        let addr_b = object::object_address(token_b);
        assert!(
            addr_fee == addr_a || addr_fee == addr_b,
            E_INVALID_TOKEN_FEE
        );
    }

    fun assert_token_fee_of_loan_position(
        position: &LoanPosition, token_fee: &Object<Metadata>
    ) {
        let addr_fee = object::object_address(token_fee);
        let addr_pos_fee = object::object_address(&position.parameters.token_fee);
        assert!(addr_fee == addr_pos_fee, E_INVALID_TOKEN_FEE);
    }

    /// Get loan position safely with error checking
    inline fun borrow_loan_position(position: Object<LoanPosition>): &LoanPosition {
        let addr = object::object_address(&position);
        assert!(object::object_exists<LoanPosition>(addr), E_LOAN_POSITION_NOT_FOUND);
        borrow_global<LoanPosition>(addr)
    }

    /// Get mutable loan position safely with error checking
    inline fun borrow_loan_position_mut(position: Object<LoanPosition>): &mut LoanPosition {
        let addr = object::object_address(&position);
        assert!(object::object_exists<LoanPosition>(addr), E_LOAN_POSITION_NOT_FOUND);
        borrow_global_mut<LoanPosition>(addr)
    }

    /// Check if position is active
    fun assert_position_active(position: &LoanPosition) {
        assert!(position.active, E_NOT_ACTIVE);
    }

    /// Calculate maximum borrowable amount
    public fun max_borrowable_amount(position: Object<LoanPosition>): u64 acquires LoanPosition {
        let pos = borrow_loan_position(position);
        pos.available_borrow
    }

    /// Calculate current utilization rate
    public fun current_utilization_rate(position: Object<LoanPosition>): u64 acquires LoanPosition {
        let pos = borrow_loan_position(position);
        if (pos.liquidity == 0) { 0 }
        else {
            (pos.total_borrowed * bps()) / (pos.liquidity as u64)
        }
    }

    // === TESTS ===
    #[test_only]
    fun init_for_testing(aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
    }

    #[test(aptos_framework = @0x1)]
    fun test_create_loan_position_only(aptos_framework: &signer) acquires LoanPositionRegistry {
        init_for_testing(aptos_framework);

        let (a_constructor_ref, _) = fungible_asset::create_test_token(aptos_framework);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &a_constructor_ref,
            option::some(1_000_000_000),
            string::utf8(b"Test A"),
            string::utf8(b"TSTA"),
            6,
            string::utf8(b"test_a"),
            string::utf8(b"https://example.com/tsta.png")
        );
        let mint_ref_a = fungible_asset::generate_mint_ref(&a_constructor_ref);
        let fungible_a = fungible_asset::mint(&mint_ref_a, 1_000_000_000);
        let token_a = fungible_asset::asset_metadata(&fungible_a);

        create_loan_position(
            aptos_framework,
            token_a,
            object::address_to_object<Metadata>(@0xa),
            token_a,
            1,
            32768 - 120,
            120,
            2000,
            4000,
            8000,
            1
        );

        fungible_asset::destroy_zero(fungible_a);
    }
}

