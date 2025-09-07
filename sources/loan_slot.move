// === FERED LOAN SLOT ===
module fered::loan_slot {
    use std::signer;
    use aptos_framework::aptos_coin;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use aptos_framework::math64;
    use aptos_framework::math128;
    use aptos_framework::error;
    use aptos_framework::debug;
    use fered::math::{bps};

    // friend fered::core;

    // === CONSTANTS ===
    const PRECISION: u128 = 1_000_000_000_000;

    // === ERRORS ===
    /// Loan slot not found
    const E_LOAN_SLOT_NOT_FOUND: u64 = 3001;
    /// Unauthorized access
    const E_UNAUTHORIZED: u64 = 3002;
    /// Loan slot is not active
    const E_NOT_ACTIVE: u64 = 3003;
    /// Loan slot already liquidated
    const E_ALREADY_LIQUIDATED: u64 = 3004;
    /// Insufficient collateral
    const E_INSUFFICIENT_COLLATERAL: u64 = 3005;

    // === STRUCTS ===
    struct LoanSlot has key {
        loan_pos_addr: address,
        principal: u64,
        colleteral: u64,
        debt_idx_at_borrow: u128,
        ts: u64,
        active: bool,
        liquidated: bool, /// Track if the loan has been liquidated
        yield_earned: u128, /// Yield earned from position on Hyperion
        withdrawn_amount: u64,
        available_withdraw: u64,
        last_payment_ts: u64
    }

    struct BorrowerToken has key {}

    struct GlobalState has key {
        supply: u128
    }

    // === INIT ===
    fun init_module(deployer: &signer) {
        move_to(deployer, GlobalState { supply: 0 });
    }

    // === CORE FUNCTIONS ===
    /// Create a new loan slot for a borrower
    ///
    /// Arguments:
    /// * `borrower` - Signer
    /// * `loan_pos_addr` - The address of the associated loan position.
    /// * `principal` - The principal amount of the loan.
    /// * `colleteral` - The collateral amount provided for the loan.
    /// * `debt_idx_at_borrow` - The debt index at the time of borrowing.
    public(friend) fun create_loan_slot(
        borrower: &signer,
        loan_pos_addr: address,
        principal: u64,
        colleteral: u64,
        debt_idx_at_borrow: u128
    ): Object<LoanSlot> {
        let ts = timestamp::now_seconds();
        let borrow_info = LoanSlot {
            loan_pos_addr,
            principal,
            colleteral,
            debt_idx_at_borrow,
            ts,
            active: true,
            liquidated: false,
            yield_earned: 0,
            available_withdraw: principal,
            withdrawn_amount: 0,
            last_payment_ts: ts
        };
        let borrower_addr = signer::address_of(borrower);
        let constructor_ref = object::create_object(borrower_addr);
        let container_signer = object::generate_signer(&constructor_ref);

        move_to(&container_signer, borrow_info);

        let loan_slot_obj =
            object::object_from_constructor_ref<LoanSlot>(&constructor_ref);

        object::transfer(borrower, loan_slot_obj, borrower_addr);

        loan_slot_obj
    }

    /// Withdraw collateral by repaying part or all of the loan
    ///
    /// Returns:
    /// * `collateral_withdrawn` - The amount of collateral withdrawn.
    /// * `interest_paid` - The interest portion paid.
    /// * `loan_repaid` - Whether the loan is fully repaid.
    /// * `new_debt_idx` - The updated debt index after repayment.
    public(friend) fun withdraw(
        borrower: &signer,
        ls_obj: Object<LoanSlot>,
        current_debt_idx: u128,
        amount: u64
    ): (u64, u64, bool, u128) acquires LoanSlot {
        assert_is_owner(borrower, ls_obj);
        // Repay the loan partially using the specified amount
        let (principal_portion, interest_portion, loan_repaid, new_debt_idx) =
            repay(borrower, ls_obj, current_debt_idx, amount);

        let loan_slot = borrow_loan_slot_mut(ls_obj);

        assert!(principal_portion > 0, E_NOT_ACTIVE);

        // Calculate collateral to withdraw based on principal portion repaid
        let collateral_to_withdraw =
            math128::mul_div(
                loan_slot.colleteral as u128,
                principal_portion as u128,
                (principal_portion + loan_slot.principal) as u128
            ) as u64;

        loan_slot.withdrawn_amount += collateral_to_withdraw;
        loan_slot.available_withdraw =
            if (loan_slot.available_withdraw >= collateral_to_withdraw) {
                loan_slot.available_withdraw - collateral_to_withdraw
            } else { 0 };

        (collateral_to_withdraw, interest_portion, loan_repaid, new_debt_idx)
    }

    /// Repay part or all of the loan
    ///
    /// Returns:
    /// * `principal_portion` - The portion of the amount that goes towards principal.
    /// * `interest_portion` - The portion that goes towards interest.
    /// * `loan_repaid` - Whether the loan is fully repaid.
    /// * `new_debt_idx` - The updated debt index after repayment.
    public(friend) fun repay(
        borrower: &signer,
        ls_obj: Object<LoanSlot>,
        current_debt_idx: u128,
        amount: u64
    ): (u64, u64, bool, u128) acquires LoanSlot {
        assert_is_owner(borrower, ls_obj);

        let loan_slot = borrow_global_mut<LoanSlot>(object::object_address(&ls_obj));

        if (!loan_slot.active || amount == 0) {
            return (0, 0, false, current_debt_idx);
        };

        let principal_scaled =
            math128::mul_div(
                (loan_slot.principal as u128),
                current_debt_idx,
                loan_slot.debt_idx_at_borrow
            );
        let amount_u128 = amount as u128;
        let (principal_portion, interest_portion) =
            if (amount_u128 >= principal_scaled) {
                (loan_slot.principal, (amount_u128 - principal_scaled) as u64)
            } else {
                let principal_portion =
                    math128::mul_div(
                        amount_u128,
                        loan_slot.debt_idx_at_borrow,
                        current_debt_idx
                    ) as u64;
                let interest_portion = amount - principal_portion;
                (principal_portion, interest_portion)
            };

        loan_slot.principal = math64::max(0, loan_slot.principal - principal_portion);
        loan_slot.last_payment_ts = timestamp::now_seconds();
        let loan_repaid = loan_slot.principal == 0;

        if (loan_repaid) {
            loan_slot.active = false;
        };

        let new_debt_idx =
            if (loan_slot.principal == 0) {
                current_debt_idx
            } else {
                math128::mul_div(
                    (loan_slot.principal as u128),
                    current_debt_idx,
                    principal_scaled
                )
            };

        (principal_portion, interest_portion, loan_repaid, new_debt_idx)
    }

    /// Liquidate an undercollateralized loan slot
    ///
    /// Returns:
    /// * `liquidated` - Whether the liquidation was successful.
    /// * `liquidation_bonus` - The bonus amount awarded to the liquidator.
    /// * `protocol_fee` - The fee amount taken by the protocol.
    /// * `remaining_collateral` - The collateral remaining after liquidation.
    public(friend) fun liquidate(
        ls_obj: Object<LoanSlot>,
        current_debt_idx: u128,
        liquidation_threshold: u64 // LTV threshold in basis points (e.g., 8500 = 85%)
    ): (bool, u64, u64, u64) acquires LoanSlot {
        let loan_slot = borrow_global_mut<LoanSlot>(object::object_address(&ls_obj));

        // Check liquidation eligibility
        if (!loan_slot.active || loan_slot.liquidated) {
            return (false, 0, 0, 0)
        };

        // Calculate current debt using debt index
        let current_debt =
            math128::mul_div(
                loan_slot.principal as u128,
                current_debt_idx,
                loan_slot.debt_idx_at_borrow
            ) as u64;

        // Calculate current LTV ratio
        let current_ltv =
            math128::mul_div(
                current_debt as u128,
                bps() as u128,
                loan_slot.colleteral as u128
            ) as u64;

        // Check if LTV exceeds liquidation threshold
        if (current_ltv < liquidation_threshold) {
            return (false, 0, 0, 0)
        };

        // Calculate liquidation amounts
        let liquidation_bonus =
            math128::mul_div(
                loan_slot.colleteral as u128,
                5u128, // 5% bonus
                100u128
            ) as u64;

        let protocol_fee =
            math128::mul_div(
                loan_slot.colleteral as u128,
                1u128, // 1% protocol fee
                100u128
            ) as u64;

        let remaining_collateral = loan_slot.colleteral - liquidation_bonus
            - protocol_fee;

        loan_slot.active = false;
        loan_slot.liquidated = true;
        loan_slot.last_payment_ts = timestamp::now_seconds();

        (true, liquidation_bonus, protocol_fee, remaining_collateral)
    }

    // === VIEW FUNCTIONS ===

    // Basic loan slot information
    public(friend) fun principal(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).principal
    }

    public(friend) fun collateral(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).colleteral
    }

    public(friend) fun debt_idx_at_borrow(
        loan_slot_obj: Object<LoanSlot>
    ): u128 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).debt_idx_at_borrow
    }

    public(friend) fun timestamp_created(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).ts
    }

    public(friend) fun last_payment_timestamp(
        loan_slot_obj: Object<LoanSlot>
    ): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).last_payment_ts
    }

    // Status functions
    public(friend) fun is_active(loan_slot_obj: Object<LoanSlot>): bool acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).active
    }

    public(friend) fun is_liquidated(loan_slot_obj: Object<LoanSlot>): bool acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).liquidated
    }

    // Yield and withdrawal functions
    public(friend) fun yield_earned(loan_slot_obj: Object<LoanSlot>): u128 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).yield_earned
    }

    public(friend) fun withdrawn_amount(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).withdrawn_amount
    }

    public(friend) fun available_withdraw(
        loan_slot_obj: Object<LoanSlot>
    ): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).available_withdraw
    }

    // Calculated view functions
    public(friend) fun current_debt(
        loan_slot_obj: Object<LoanSlot>, current_debt_idx: u128
    ): u64 acquires LoanSlot {
        let loan_slot = borrow_loan_slot(loan_slot_obj);
        math128::mul_div(
            loan_slot.principal as u128,
            current_debt_idx,
            loan_slot.debt_idx_at_borrow
        ) as u64
    }

    public(friend) fun current_ltv(
        loan_slot_obj: Object<LoanSlot>, current_debt_idx: u128
    ): u64 acquires LoanSlot {
        let debt = current_debt(loan_slot_obj, current_debt_idx);
        let loan_slot = borrow_loan_slot(loan_slot_obj);
        math128::mul_div(
            debt as u128,
            bps() as u128,
            loan_slot.colleteral as u128
        ) as u64
    }

    public(friend) fun loan_slot_address(loan_slot_obj: Object<LoanSlot>): address acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).loan_pos_addr
    }

    // Global state view
    public(friend) fun total_supply(): u128 acquires GlobalState {
        borrow_global<GlobalState>(@fered).supply
    }

    // === HELPER FUNCTIONS ===

    inline fun borrow_loan_slot(object: Object<LoanSlot>): &LoanSlot {
        let addr = object::object_address(&object);
        assert!(object::object_exists<LoanSlot>(addr), E_LOAN_SLOT_NOT_FOUND);
        borrow_global<LoanSlot>(addr)
    }

    inline fun borrow_loan_slot_mut(object: Object<LoanSlot>): &mut LoanSlot {
        let addr = object::object_address(&object);
        assert!(object::object_exists<LoanSlot>(addr), E_LOAN_SLOT_NOT_FOUND);
        borrow_global_mut<LoanSlot>(addr)
    }

    fun assert_is_owner(signer: &signer, ls_obj: Object<LoanSlot>) {
        let signer_addr = signer::address_of(signer);
        assert!(
            object::is_owner(ls_obj, signer_addr),
            error::permission_denied(E_UNAUTHORIZED)
        );
    }

    // === TESTS ===

    #[test_only]
    fun init_for_test(deployer: &signer, aptos_framework: &signer) {
        aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
        timestamp::set_time_has_started_for_testing(aptos_framework);
        init_module(deployer);
    }

    #[test(
        fered = @fered, aptos_framework = @0x1, borrower = @0x123, loan_slot = @0x456
    )]
    fun test_basic_flow(
        fered: &signer,
        aptos_framework: &signer,
        borrower: &signer,
        loan_slot: address
    ) {
        init_for_test(fered, aptos_framework);
        create_loan_slot(borrower, loan_slot, 1000, 2000, 123456789);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_create_loan_slot_basic(
        fered: &signer, aptos_framework: &signer, borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        let loan_slot_addr = @0x456;
        let principal = 1000u64;
        let collateral = 2000u64;
        let debt_idx = 1000000000000u128;

        let loan_obj =
            create_loan_slot(
                borrower,
                loan_slot_addr,
                principal,
                collateral,
                debt_idx
            );

        // Verify loan slot properties
        assert!(principal(loan_obj) == principal, 1);
        assert!(collateral(loan_obj) == collateral, 2);
        assert!(debt_idx_at_borrow(loan_obj) == debt_idx, 3);
        assert!(is_active(loan_obj), 4);
        assert!(!is_liquidated(loan_obj), 5);
        assert!(withdrawn_amount(loan_obj) == principal, 6);
        assert!(available_withdraw(loan_obj) == 0, 7);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_create_multiple_loan_slots(
        fered: &signer, aptos_framework: &signer, borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        // Create first loan slot
        let loan1 = create_loan_slot(borrower, @0x111, 500, 1000, 1000000000000);
        // Create second loan slot
        let loan2 = create_loan_slot(borrower, @0x222, 1500, 3000, 1200000000000);

        // Verify both exist and have correct values
        assert!(principal(loan1) == 500, 1);
        assert!(principal(loan2) == 1500, 2);
        assert!(collateral(loan1) == 1000, 3);
        assert!(collateral(loan2) == 3000, 4);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_withdraw_partial_with_params(
        fered: &signer, aptos_framework: &signer, borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        let loan_obj = create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);

        let current_debt_idx = 1000000005000u128;
        let withdraw_amount = 300u64;

        let (collateral_withdrawn, interest_paid, loan_repaid, new_debt_idx) =
            withdraw(
                borrower,
                loan_obj,
                current_debt_idx,
                withdraw_amount
            );

        let expected_interest_portion = 1u64; // 300 - 299
        let expected_collateral_withdrawn = 598u64; // 2000 * 299 / 1000
        let expected_remaining_principal = 701u64; // 1000 - 299

        let principal_after = principal(loan_obj);

        assert!(collateral_withdrawn == expected_collateral_withdrawn, 1);
        assert!(interest_paid == expected_interest_portion, 2);
        assert!(!loan_repaid, 3);
        assert!(new_debt_idx > 0, 4);
        assert!(principal_after == expected_remaining_principal, 5);

        let withdrawn = withdrawn_amount(loan_obj);
        let available = available_withdraw(loan_obj);
        let principal = principal(loan_obj);

        assert!(withdrawn >= collateral_withdrawn, 4);
        assert!(available <= principal, 5);

        let active = is_active(loan_obj);
        assert!(active == !loan_repaid, 6);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_withdraw_full_repayment(
        fered: &signer, aptos_framework: &signer, borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        let loan_obj = create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);

        let current_debt_idx = 1000000005000u128;
        let withdraw_amount = 1005u64; // Đủ để trả hết principal + interest

        let (collateral_withdrawn, interest_paid, loan_repaid, new_debt_idx) =
            withdraw(
                borrower,
                loan_obj,
                current_debt_idx,
                withdraw_amount
            );

        assert!(collateral_withdrawn == 2000, 1);
        assert!(interest_paid == 5, 2);
        assert!(loan_repaid, 3);
        assert!(new_debt_idx == current_debt_idx, 4);

        let final_principal = principal(loan_obj);
        let withdrawn = withdrawn_amount(loan_obj);
        let available = available_withdraw(loan_obj);

        assert!(final_principal == 0, 5);
        assert!(withdrawn == 2000, 6);
        assert!(available == 0, 7);

        assert!(!is_active(loan_obj), 8);
        assert!(!is_liquidated(loan_obj), 9);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_repay_inactive_loan(
        fered: &signer, aptos_framework: &signer, borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        let loan_obj = create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);

        let current_debt_idx = 1000000005000u128;
        let (_, _, _, new_debt_idx) = repay(borrower, loan_obj, current_debt_idx, 1500);

        let (principal_portion, interest_portion, loan_repaid, newest_debt_idx) =
            repay(borrower, loan_obj, new_debt_idx, 100);

        assert!(principal_portion == 0, 1);
        assert!(interest_portion == 0, 2);
        assert!(!loan_repaid, 3);
        assert!(newest_debt_idx == new_debt_idx, 4);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_liquidation_success(
        fered: &signer,
        aptos_framework: &signer,
        borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        let loan_obj = create_loan_slot(borrower, @0x456, 1000, 1200, 1000000000000);
        // High debt index to trigger liquidation (debt grows to make LTV > threshold)
        let high_debt_idx = 2000000000000u128; // 100% increase
        let liquidation_threshold = 8500u64; // 85%

        let (liquidated, bonus, protocol_fee, remaining) =
            liquidate(
                loan_obj,
                high_debt_idx,
                liquidation_threshold
            );

        assert!(liquidated, 1);
        assert!(bonus == 60, 2); // 5% of 1200 collateral
        assert!(protocol_fee == 12, 3); // 1% of 1200 collateral
        assert!(remaining == 1128, 4); // 1200 - 60 - 12
        assert!(!is_active(loan_obj), 5);
        assert!(is_liquidated(loan_obj), 6);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_liquidation_healthy_loan(
        fered: &signer,
        aptos_framework: &signer,
        borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        let loan_obj = create_loan_slot(borrower, @0x456, 1000, 3000, 1000000000000);
        let normal_debt_idx = 1100000000000u128; // 10% increase
        let liquidation_threshold = 8500u64;

        let (liquidated, bonus, protocol_fee, remaining) =
            liquidate(
                loan_obj,
                normal_debt_idx,
                liquidation_threshold
            );

        // Should not liquidate healthy loan
        assert!(!liquidated, 1);
        assert!(bonus == 0, 2);
        assert!(protocol_fee == 0, 3);
        assert!(remaining == 0, 4);
        assert!(is_active(loan_obj), 5);
        assert!(!is_liquidated(loan_obj), 6);
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_high_precision_calculations(
        fered: &signer, aptos_framework: &signer, borrower: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        // Test with very small principal and large debt index changes
        let loan_obj = create_loan_slot(borrower, @0x456, 1, 1000000, 1000000000000);
        let high_debt_idx = 5000000000000u128; // 5x increase

        let debt = current_debt(loan_obj, high_debt_idx);
        assert!(debt == 5, 1); // 1 * 5 = 5

        let ltv = current_ltv(loan_obj, high_debt_idx);
        assert!(ltv == 0, 2); // Very small LTV due to large collateral
    }

    #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
    fun test_loan_lifecycle(
        fered: &signer,
        aptos_framework: &signer,
        borrower: &signer,
        liquidator: &signer
    ) acquires LoanSlot {
        init_for_test(fered, aptos_framework);

        // Create loan
        let loan_obj = create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);

        // Make partial repayment
        let debt_idx_1 = 1100000000000u128;
        let (p1, i1, repaid1, _) = repay(borrower, loan_obj, debt_idx_1, 300);
        assert!(!repaid1, 1);
        assert!(p1 + i1 == 300, 2);

        // Time passes, debt grows
        let debt_idx_2 = 1300000000000u128;

        // Try liquidation (should fail - healthy)
        let (liquidated1, _, _, _) = liquidate(loan_obj, debt_idx_2, 8500);
        assert!(!liquidated1, 3);

        // More time passes, debt grows significantly
        let debt_idx_3 = 2500000000000u128;

        // Liquidation should succeed now
        let (liquidated2, bonus, fee, remaining) = liquidate(loan_obj, debt_idx_3, 8500);
        assert!(liquidated2, 4);
        assert!(bonus > 0, 5);
        assert!(fee > 0, 6);
        assert!(remaining > 0, 7);
        assert!(!is_active(loan_obj), 8);
        assert!(is_liquidated(loan_obj), 9);
    }
}

