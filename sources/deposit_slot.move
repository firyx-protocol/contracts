module firyx::deposit_slot {
    use std::signer;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use aptos_framework::math128;
    use aptos_framework::error;
    use firyx::math::{bps};
    use firyx::events;

    friend firyx::loan_position;

    // === CONSTANTS ===
    const PRECISION: u128 = 1_000_000_000_000;

    // === ERRORS ===
    /// Deposit slot not found
    const E_DEPOSIT_SLOT_NOT_FOUND: u64 = 4001;
    /// Unauthorized access
    const E_UNAUTHORIZED: u64 = 4002;
    /// Deposit slot is not active
    const E_NOT_ACTIVE: u64 = 4003;
    /// Invalid amount
    const E_INVALID_AMOUNT: u64 = 4004;
    /// Insufficient balance for withdrawal
    const E_INSUFFICIENT_BALANCE: u64 = 4005;
    /// Zero principal amount
    const E_ZERO_PRINCIPAL: u64 = 4006;
    /// Zero shares amount
    const E_ZERO_SHARES: u64 = 4007;

    // === STRUCTS ===
    struct DepositSlot has key {
        loan_pos_addr: address,
        lender: address,
        original_principal: u128, // Original deposit amount
        accumulated_deposits: u128, // Total amount deposited
        fee_growth_debt_a: u128,
        fee_growth_debt_b: u128,
        share: u64, // Shares ownership trong pool
        created_at_ts: u64,
        active: bool,
        last_deposit_ts: u64,
        last_withdraw_ts: u64
    }

    struct GlobalState has key {
        total_deposits: u64,
        active_deposits: u64
    }

    // === INIT ===
    fun init_module(deployer: &signer) {
        move_to(
            deployer,
            GlobalState { total_deposits: 0, active_deposits: 0 }
        );
    }

    // === CORE FUNCTIONS ===

    /// Create a new deposit slot for a lender
    ///
    /// Arguments:
    /// * `lender` - Signer
    /// * `loan_pos_addr` - The address of the associated loan position
    /// * `principal` - The principal amount of the deposit
    /// * `shares` - The shares allocated for this deposit
    public(friend) fun create_deposit_slot(
        lender: &signer,
        loan_pos_addr: address,
        principal: u128,
        shares: u64
    ): Object<DepositSlot> acquires GlobalState {
        let ts = timestamp::now_seconds();
        let deposit_info = DepositSlot {
            loan_pos_addr,
            lender: signer::address_of(lender),
            original_principal: principal,
            accumulated_deposits: principal,
            fee_growth_debt_a: 0,
            fee_growth_debt_b: 0,
            share: shares,
            created_at_ts: ts,
            active: true,
            last_deposit_ts: ts,
            last_withdraw_ts: 0
        };

        let lender_addr = signer::address_of(lender);
        let constructor_ref = object::create_object(lender_addr);
        let container_signer = object::generate_signer(&constructor_ref);

        move_to(&container_signer, deposit_info);

        let state = borrow_global_mut<GlobalState>(@firyx);
        state.total_deposits += 1;
        state.active_deposits += 1;

        let deposit_slot_obj =
            object::object_from_constructor_ref<DepositSlot>(&constructor_ref);
        object::transfer(lender, deposit_slot_obj, lender_addr);

        // Emit event
        events::emit_deposit_slot_created(
            object::object_address(&deposit_slot_obj),
            lender_addr,
            loan_pos_addr,
            principal,
            shares,
            ts
        );

        deposit_slot_obj
    }

    /// Deposit more liquidity to existing or new deposit slot
    ///
    /// Returns:
    /// * `new_shares` - The new shares allocated for this deposit
    /// * `total_shares` - Total shares after deposit
    /// * `position_percentage` - Percentage of total position (in basis points)
    /// * `is_new_deposit` - Whether this is a new deposit or additional deposit
    public(friend) fun deposit(
        lender: &signer,
        ds_obj: Object<DepositSlot>,
        amount: u128,
        total_pool_liquidity: u128,
        total_pool_shares: u64
    ): (u64, u64, u64, bool) acquires DepositSlot {
        assert_is_owner(lender, ds_obj);
        assert_valid_amount(amount);

        let deposit_slot = borrow_deposit_slot_mut(ds_obj);
        assert_is_active(deposit_slot);

        // Calculate shares based on current pool state
        let new_shares =
            if (total_pool_shares == 0 && total_pool_liquidity == 0) {
                // First deposit in pool: shares = amount
                (amount as u64)
            } else if (total_pool_shares > 0 && total_pool_liquidity > 0) {
                // shares = (amount * total_existing_shares) / total_existing_liquidity
                math128::mul_div(
                    amount,
                    total_pool_shares as u128,
                    total_pool_liquidity
                ) as u64
            } else {
                abort E_INVALID_AMOUNT
            };

        let is_new_deposit = deposit_slot.accumulated_deposits == 0;

        // Update deposit info
        deposit_slot.accumulated_deposits += amount;
        deposit_slot.share += new_shares;
        deposit_slot.last_deposit_ts = timestamp::now_seconds();

        // Calculate position percentage in the pool (in basis points)
        let new_total_shares = total_pool_shares + new_shares;
        let position_percentage =
            if (new_total_shares > 0) {
                math128::mul_div(
                    deposit_slot.share as u128,
                    bps() as u128,
                    new_total_shares as u128
                ) as u64
            } else {
                bps() // 100% if only deposit
            };

        // Emit event
        events::emit_deposit_added(
            object::object_address(&ds_obj),
            signer::address_of(lender),
            amount,
            new_shares,
            deposit_slot.share,
            deposit_slot.accumulated_deposits,
            position_percentage,
            is_new_deposit,
            deposit_slot.last_deposit_ts
        );

        (new_shares, deposit_slot.share, position_percentage, is_new_deposit)
    }

    /// Withdraw liquidity based on amount
    ///
    /// Returns:
    /// * `shares_burned` - The shares burned for this withdrawal
    /// * `remaining_shares` - Remaining shares after withdrawal
    /// * `position_percentage` - Updated percentage of total position (in basis points)
    /// * `fully_withdrawn` - Whether the deposit is fully withdrawn
    public(friend) fun withdraw(
        lender: &signer,
        ds_obj: Object<DepositSlot>,
        amount: u128,
        total_pool_liquidity: u128,
        total_pool_shares: u64
    ): (u64, u64, u64, bool) acquires DepositSlot, GlobalState {
        assert_is_owner(lender, ds_obj);
        assert_valid_amount(amount);

        let deposit_slot = borrow_deposit_slot_mut(ds_obj);
        assert_is_active(deposit_slot);

        // Calculate shares to burn based on current pool value
        let shares_to_burn =
            if (total_pool_shares > 0 && total_pool_liquidity > 0) {
                math128::mul_div(
                    amount,
                    total_pool_shares as u128,
                    total_pool_liquidity
                ) as u64
            } else if (total_pool_shares == 0 && total_pool_liquidity == 0) {
                (amount as u64)
            } else {
                abort E_INVALID_AMOUNT
            };

        assert_sufficient_shares(deposit_slot, shares_to_burn);

        // Update deposit info based on shares burned, not amount
        deposit_slot.share -= shares_to_burn;
        let withdrawal_value =
            if (total_pool_shares > 0) {
                math128::mul_div(
                    shares_to_burn as u128,
                    total_pool_liquidity,
                    total_pool_shares as u128
                )
            } else { amount };

        deposit_slot.accumulated_deposits =
            if (deposit_slot.accumulated_deposits >= withdrawal_value) {
                deposit_slot.accumulated_deposits - withdrawal_value
            } else { 0 };
        deposit_slot.last_withdraw_ts = timestamp::now_seconds();

        let fully_withdrawn = deposit_slot.share == 0;

        // If fully withdrawn, mark as inactive
        if (fully_withdrawn) {
            deposit_slot.active = false;
            // Update global state
            let state = borrow_global_mut<GlobalState>(@firyx);
            state.active_deposits -= 1;
        };

        // Calculate updated position percentage
        let new_total_shares = total_pool_shares - shares_to_burn;
        let position_percentage =
            if (new_total_shares > 0 && !fully_withdrawn) {
                math128::mul_div(
                    deposit_slot.share as u128,
                    bps() as u128,
                    new_total_shares as u128
                ) as u64
            } else { 0 };

        // Emit event
        events::emit_deposit_withdrawn(
            object::object_address(&ds_obj),
            signer::address_of(lender),
            amount,
            shares_to_burn,
            deposit_slot.share,
            deposit_slot.accumulated_deposits,
            position_percentage,
            fully_withdrawn,
            deposit_slot.last_withdraw_ts
        );

        (shares_to_burn, deposit_slot.share, position_percentage, fully_withdrawn)
    }

    // === ASSERT FUNCTIONS ===
    fun assert_is_owner(signer: &signer, ds_obj: Object<DepositSlot>) {
        let signer_addr = signer::address_of(signer);
        assert!(
            object::is_owner(ds_obj, signer_addr),
            error::permission_denied(E_UNAUTHORIZED)
        );
    }

    fun assert_is_active(deposit_slot: &DepositSlot) {
        assert!(deposit_slot.active, E_NOT_ACTIVE);
    }

    fun assert_valid_amount(amount: u128) {
        assert!(amount > 0, E_INVALID_AMOUNT);
    }

    fun assert_sufficient_shares(
        deposit_slot: &DepositSlot, required_shares: u64
    ) {
        assert!(required_shares <= deposit_slot.share, E_INSUFFICIENT_BALANCE);
    }

    fun assert_non_zero_principal(principal: u128) {
        assert!(principal > 0, E_ZERO_PRINCIPAL);
    }

    fun assert_non_zero_shares(shares: u64) {
        assert!(shares > 0, E_ZERO_SHARES);
    }

    // === VIEW FUNCTIONS ===
    #[view]
    public fun get_deposit_slot_info(
        ds_obj: Object<DepositSlot>
    ): (
        address, // loan_pos_addr
        address, // lender
        u128, // original_principal
        u128, // accumulated_deposits
        u64, // share
        u64, // created_at_ts
        bool, // active
        u64, // last_deposit_ts
        u64, // last_withdraw_ts
        u128, // fee_growth_debt_a
        u128 // fee_growth_debt_b
    ) acquires DepositSlot {
        let deposit_slot = borrow_deposit_slot(ds_obj);
        (
            deposit_slot.loan_pos_addr,
            deposit_slot.lender,
            deposit_slot.original_principal,
            deposit_slot.accumulated_deposits,
            deposit_slot.share,
            deposit_slot.created_at_ts,
            deposit_slot.active,
            deposit_slot.last_deposit_ts,
            deposit_slot.last_withdraw_ts,
            deposit_slot.fee_growth_debt_a,
            deposit_slot.fee_growth_debt_b
        )
    }

    // Basic deposit slot information
    #[view]
    public fun original_principal(deposit_slot_obj: Object<DepositSlot>): u128 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).original_principal
    }

    #[view]
    public fun accumulated_deposits(
        deposit_slot_obj: Object<DepositSlot>
    ): u128 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).accumulated_deposits
    }

    #[view]
    public fun share(deposit_slot_obj: Object<DepositSlot>): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).share
    }

    #[view]
    public fun timestamp_created(deposit_slot_obj: Object<DepositSlot>): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).created_at_ts
    }

    #[view]
    public fun last_deposit_timestamp(
        deposit_slot_obj: Object<DepositSlot>
    ): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).last_deposit_ts
    }

    #[view]
    public fun last_withdraw_timestamp(
        deposit_slot_obj: Object<DepositSlot>
    ): u64 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).last_withdraw_ts
    }

    // Status functions
    #[view]
    public fun is_active(deposit_slot_obj: Object<DepositSlot>): bool acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).active
    }

    #[view]
    public fun lender_address(deposit_slot_obj: Object<DepositSlot>): address acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).lender
    }

    #[view]
    public fun loan_position_address(
        deposit_slot_obj: Object<DepositSlot>
    ): address acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).loan_pos_addr
    }

    #[view]
    public fun fee_growth_debt_a(deposit_slot_obj: Object<DepositSlot>): u128 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).fee_growth_debt_a
    }

    #[view]
    public fun fee_growth_debt_b(deposit_slot_obj: Object<DepositSlot>): u128 acquires DepositSlot {
        borrow_deposit_slot(deposit_slot_obj).fee_growth_debt_b
    }

    // Global state view
    #[view]
    public fun total_deposits(): u64 acquires GlobalState {
        borrow_global<GlobalState>(@firyx).total_deposits
    }

    #[view]
    public fun active_deposits(): u64 acquires GlobalState {
        borrow_global<GlobalState>(@firyx).active_deposits
    }

    // Calculate current withdrawal value based on pool state
    public fun current_withdrawal_value(
        deposit_slot_obj: Object<DepositSlot>,
        total_pool_liquidity: u128,
        total_pool_shares: u64
    ): u128 acquires DepositSlot {
        let deposit_slot = borrow_deposit_slot(deposit_slot_obj);

        if (total_pool_shares == 0 && total_pool_liquidity == 0) {
            return deposit_slot.accumulated_deposits
        } else if (total_pool_shares > 0 && total_pool_liquidity > 0) {
            return math128::mul_div(
                deposit_slot.share as u128,
                total_pool_liquidity,
                total_pool_shares as u128
            )
        } else {
            return 0
        }
    }

    // === FRIEND FUNCTIONS FOR FEE GROWTH TRACKING ===

    public(friend) fun update_fee_growth_debt(
        ds_obj: Object<DepositSlot>, fee_growth_global_a: u128, fee_growth_global_b: u128
    ) acquires DepositSlot {
        let deposit_slot = borrow_deposit_slot_mut(ds_obj);
        deposit_slot.fee_growth_debt_a = fee_growth_global_a;
        deposit_slot.fee_growth_debt_b = fee_growth_global_b;
    }

    public(friend) fun calculate_pending_yield(
        ds_obj: Object<DepositSlot>, fee_growth_global_a: u128, fee_growth_global_b: u128
    ): (u128, u128) acquires DepositSlot {
        let deposit_slot = borrow_deposit_slot(ds_obj);

        let pending_yield_a =
            if (fee_growth_global_a >= deposit_slot.fee_growth_debt_a) {
                math128::mul_div(
                    deposit_slot.share as u128,
                    fee_growth_global_a - deposit_slot.fee_growth_debt_a,
                    PRECISION
                )
            } else { 0 };

        let pending_yield_b =
            if (fee_growth_global_b >= deposit_slot.fee_growth_debt_b) {
                math128::mul_div(
                    deposit_slot.share as u128,
                    fee_growth_global_b - deposit_slot.fee_growth_debt_b,
                    PRECISION
                )
            } else { 0 };

        (pending_yield_a, pending_yield_b)
    }

    // === HELPER FUNCTIONS ===

    inline fun borrow_deposit_slot(object: Object<DepositSlot>): &DepositSlot {
        let addr = object::object_address(&object);
        assert!(object::object_exists<DepositSlot>(addr), E_DEPOSIT_SLOT_NOT_FOUND);
        borrow_global<DepositSlot>(addr)
    }

    inline fun borrow_deposit_slot_mut(object: Object<DepositSlot>): &mut DepositSlot {
        let addr = object::object_address(&object);
        assert!(object::object_exists<DepositSlot>(addr), E_DEPOSIT_SLOT_NOT_FOUND);
        borrow_global_mut<DepositSlot>(addr)
    }

    // === TESTS ===

    #[test_only]
    fun init_for_test(deployer: &signer, aptos_framework: &signer) {
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(deployer);
    }

    #[test(firyx = @firyx, aptos_framework = @0x1, lender = @0x123)]
    fun test_create_deposit_slot_basic(
        firyx: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(firyx, aptos_framework);

        let loan_pos_addr = @0x456;
        let principal = 1000u128;
        let shares = 1000u64;

        let deposit_obj = create_deposit_slot(lender, loan_pos_addr, principal, shares);

        // Verify deposit slot properties
        assert!(accumulated_deposits(deposit_obj) == principal, 1);
        assert!(shares(deposit_obj) == shares, 2);
        assert!(is_active(deposit_obj), 3);
        assert!(lender_address(deposit_obj) == signer::address_of(lender), 4);
        assert!(total_deposits() == 1, 5);
    }

    #[test(firyx = @firyx, aptos_framework = @0x1, lender = @0x123)]
    fun test_deposit_first_in_pool(
        firyx: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(firyx, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 0, 0);
        let amount = 1000u128;
        let total_pool_liquidity = 0u128;
        let total_pool_shares = 0u64;

        let (new_shares, total_shares, position_pct, is_new) =
            deposit(
                lender,
                deposit_obj,
                amount,
                total_pool_liquidity,
                total_pool_shares
            );

        assert!(new_shares == (amount as u64), 1); // First deposit: shares = amount
        assert!(total_shares == (amount as u64), 2);
        assert!(accumulated_deposits(deposit_obj) == amount, 3);
        assert!(is_new, 4);
        assert!(position_pct == bps(), 5); // 100%
    }

    #[test(firyx = @firyx, aptos_framework = @0x1, lender = @0x123)]
    fun test_deposit_additional_liquidity(
        firyx: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(firyx, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);
        let additional_amount = 500u128;
        let total_pool_liquidity = 5000u128;
        let total_pool_shares = 5000u64;

        let (new_shares, total_shares, position_pct, is_new) =
            deposit(
                lender,
                deposit_obj,
                additional_amount,
                total_pool_liquidity,
                total_pool_shares
            );

        // shares = (500 * 5000) / 5000 = 500
        assert!(new_shares == 500, 1);
        assert!(total_shares == 1500, 2);
        assert!(accumulated_deposits(deposit_obj) == 1500, 3);
        assert!(!is_new, 4);
        assert!(position_pct > 0, 5);
    }

    #[test(firyx = @firyx, aptos_framework = @0x1, lender = @0x123)]
    fun test_withdraw_partial(
        firyx: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(firyx, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);
        let withdraw_amount = 300u128;
        let total_pool_liquidity = 5000u128;
        let total_pool_shares = 5000u64;

        let (shares_burned, remaining_shares, _position_pct, fully_withdrawn) =
            withdraw(
                lender,
                deposit_obj,
                withdraw_amount,
                total_pool_liquidity,
                total_pool_shares
            );

        // shares_burned = (300 * 5000) / 5000 = 300
        assert!(shares_burned == 300, 1);
        assert!(remaining_shares == 700, 2);
        assert!(!fully_withdrawn, 3);
        assert!(is_active(deposit_obj), 4);
    }

    #[test(firyx = @firyx, aptos_framework = @0x1, lender = @0x123)]
    fun test_withdraw_full(
        firyx: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(firyx, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);
        let total_pool_liquidity = 1000u128;
        let total_pool_shares = 1000u64;

        let (shares_burned, remaining_shares, position_pct, fully_withdrawn) =
            withdraw(
                lender,
                deposit_obj,
                1000u128, // full amount
                total_pool_liquidity,
                total_pool_shares
            );

        assert!(shares_burned == 1000, 1);
        assert!(remaining_shares == 0, 2);
        assert!(fully_withdrawn, 3);
        assert!(!is_active(deposit_obj), 4);
        assert!(position_pct == 0, 5);
    }

    #[test(firyx = @firyx, aptos_framework = @0x1, lender = @0x123)]
    fun test_current_withdrawal_value(
        firyx: &signer, aptos_framework: &signer, lender: &signer
    ) acquires DepositSlot, GlobalState {
        init_for_test(firyx, aptos_framework);

        let deposit_obj = create_deposit_slot(lender, @0x456, 1000, 1000);

        // Pool has grown due to interest
        let total_pool_liquidity = 6000u128; // 20% growth
        let total_pool_shares = 5000u64;

        let withdrawal_value =
            current_withdrawal_value(
                deposit_obj,
                total_pool_liquidity,
                total_pool_shares
            );

        // value = (1000 * 6000) / 5000 = 1200
        assert!(withdrawal_value == 1200, 1);
    }
}

