module fered::loan_position {
    use aptos_framework::object::{Self, Object};
    use aptos_framework::account::SignerCapability;
    use aptos_framework::timestamp;
    use aptos_framework::fungible_asset::{Self, Metadata};
    use dex_contract::position_v3::Info;
    use dex_contract::router_v3;
    use aptos_framework::math64;
    use aptos_framework::math128;
    use fered::math::{Self, bps, precision};

    struct LoanPositionParameters has copy, drop, store {
        ltv: u64,
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64,
        risk_factor: u64
    }

    struct LoanPositionCap has drop, store {
        signer_cap: SignerCapability
    }

    struct LoanPosition has key {
        lp_object: Object<Info>,
        liquidity: u128,
        utilization: u64,
        current_debt_idx: u128,
        available_borrow: u64,
        total_borrowed: u64,
        parameters: LoanPositionParameters,
        lending_position_cap: LoanPositionCap,

        // Extended tracking
        created_at: u64,
        last_update_ts: u64,
        last_accrual_ts: u64,
        total_interest_earned: u128,
        active_loans_count: u64
    }

    public fun create_loan_position(
        lp_object: Object<Info>,
        signer_cap: SignerCapability,
        ltv: u64,
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64,
        risk_factor: u64
    ): Object<LoanPosition> {
        let constructor_ref = object::create_object(@fered);
        let lending_position_object =
            object::object_from_constructor_ref<LoanPosition>(&constructor_ref);
        let container_signer = object::generate_signer(&constructor_ref);

        move_to(
            &container_signer,
            LoanPosition {
                lp_object,
                liquidity: 0,
                utilization: 0,
                current_debt_idx: precision(),
                available_borrow: 0,
                total_borrowed: 0,
                parameters: LoanPositionParameters {
                    ltv,
                    slope_before_kink,
                    slope_after_kink,
                    kink_utilization,
                    risk_factor
                },
                lending_position_cap: LoanPositionCap { signer_cap },
                created_at: timestamp::now_seconds(),
                last_update_ts: timestamp::now_seconds(),
                last_accrual_ts: timestamp::now_seconds(),
                total_interest_earned: 0,
                active_loans_count: 0
            }
        );

        object::transfer(&container_signer, lending_position_object, @fered);

        lending_position_object
    }

    public fun deposit_liquidity(
        position: Object<LoanPosition>, amount: u128
    ) acquires LoanPosition {
        let pos = borrow_global_mut<LoanPosition>(object::object_address(&position));

        pos.liquidity += amount;
        pos.available_borrow = ((pos.liquidity * (pos.parameters.ltv as u128)) / 10000) as u64;
        pos.last_update_ts = timestamp::now_seconds();
    }

    public fun deposit_liquidity_single(
        lender: &signer,
        position: Object<LoanPosition>,
        from_a: Object<Metadata>,
        to_b: Object<Metadata>,
        amount_in: u64,
        slippage_numerators: u256,
        slippage_denominator: u256,
        threshold_numerator: u256,
        threshold_denominator: u256
    ) acquires LoanPosition {
        let pos_adrr = object::object_address(&position);
        let pos = borrow_global_mut<LoanPosition>(pos_adrr);

        router_v3::add_liquidity_single(
            lender,
            pos.lp_object,
            from_a,
            to_b,
            amount_in,
            slippage_numerators,
            slippage_denominator,
            threshold_numerator,
            threshold_denominator
        );

        add_liquidity_internal(pos, amount_in as u128);
    }

    public fun add_borrow(position: Object<LoanPosition>, amount: u64) acquires LoanPosition {
        let pos = borrow_global_mut<LoanPosition>(object::object_address(&position));
        pos.total_borrowed += amount;
        pos.available_borrow -= amount;
        pos.utilization = (pos.total_borrowed * 10000) / (pos.liquidity as u64);
        pos.active_loans_count += 1;
        pos.last_update_ts = timestamp::now_seconds();
    }

    fun add_liquidity_internal(
        position: &mut LoanPosition, amount: u128
    ) {}

    #[view]
    public fun calculate_base_apr(
        base_rate: u64,
        utilization: u64,
        slope_before_kink: u64,
        slope_after_kink: u64,
        kink_utilization: u64
    ): u64 {
        let max_util = math64::max(0, utilization - kink_utilization);
        let max_util_pow_1_5 = math64::sqrt(max_util) * max_util;

        base_rate + slope_before_kink * utilization / bps()
            + slope_after_kink * max_util_pow_1_5 / bps()
    }

    #[view]
    fun calculate_liquidation_threshold(
        util_bps: u64, safety_multiplier_bps: u64
    ): u64 {
        let initial_ltv =
            math128::mul_div(
                util_bps as u128,
                bps() as u128,
                (bps() - util_bps) as u128
            ) as u64;

        let threshold_with_safety =
            math128::mul_div(
                initial_ltv as u128,
                safety_multiplier_bps as u128,
                bps() as u128
            ) as u64;

        let buffer = 300;

        threshold_with_safety + buffer
    }

    #[view]
    public fun lending_position(position_addr: address): Object<LoanPosition> {
        object::address_to_object<LoanPosition>(position_addr)
    }

    #[view]
    public fun get_position_info(
        position: Object<LoanPosition>
    ): (u128, u64, u64, u64) acquires LoanPosition {
        let pos = borrow_global<LoanPosition>(object::object_address(&position));
        (pos.liquidity, pos.utilization, pos.available_borrow, pos.total_borrowed)
    }
}

