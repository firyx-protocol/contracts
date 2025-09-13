module fered::loan_slot {
    use std::signer;
    use aptos_framework::object::{Self, Object};
    use aptos_framework::option::{Self, Option};
    use aptos_framework::timestamp;
    use aptos_framework::math64;
    use aptos_framework::math128;
    use aptos_framework::error;
    use fered::events;

    friend fered::loan_position;

    // === CONSTANTS ===
    const PRECISION: u128 = 1_000_000_000_000;

    // === ERRORS ===
    /// Loan slot not found
    const E_LOAN_SLOT_NOT_FOUND: u64 = 3001;
    /// Unauthorized access
    const E_UNAUTHORIZED: u64 = 3002;
    /// Loan slot is not active
    const E_NOT_ACTIVE: u64 = 3003;
    /// Insufficient reserve in the loan slot
    const E_INSUFFICIENT_RESERVE: u64 = 3005;
    /// Amount must be greater than zero
    const E_ZERO_AMOUNT: u64 = 3006;
    /// Invalid debt index
    const E_INVALID_DEBT_INDEX: u64 = 3007;
    /// Principal must be greater than zero
    const E_ZERO_PRINCIPAL: u64 = 3008;

    // === STRUCTS ===
    struct LoanSlot has key {
        loan_pos_addr: address,
        principal: u64,              // Current remaining principal
        original_principal: u64,     // Original principal for accurate debt calculation
        share: u64,
        reserve: u64,
        debt_idx_at_borrow: u128,
        created_at_ts: u64,
        active: bool,
        yield_earned: u128,
        withdrawn_amount: u64,
        available_withdraw: u64,
        last_payment_ts: u64,
        arrears_start_ts: Option<u64>
    }

    struct GlobalState has key {
        supply: u128
    }

    // === INIT ===
    fun init_module(deployer: &signer) {
        move_to(deployer, GlobalState { supply: 0 });
    }

    // === CORE FUNCTIONS ===
    public(friend) fun create_loan_slot(
        borrower: &signer,
        loan_pos_addr: address,
        principal: u64,
        share: u64,
        reserve: u64,
        debt_idx_at_borrow: u128,
    ): Object<LoanSlot> {
        assert_valid_amounts(principal, share, reserve);
        assert_valid_debt_index(debt_idx_at_borrow);
        
        let ts = timestamp::now_seconds();
        let borrow_info = LoanSlot {
            loan_pos_addr,
            principal,
            original_principal: principal,  // Store original principal
            share,
            reserve,
            debt_idx_at_borrow,
            created_at_ts: ts,
            active: true,
            yield_earned: 0,
            available_withdraw: principal,
            withdrawn_amount: 0,
            last_payment_ts: ts,
            arrears_start_ts: option::none<u64>()
        };
        
        let borrower_addr = signer::address_of(borrower);
        let constructor_ref = object::create_object(borrower_addr);
        let container_signer = object::generate_signer(&constructor_ref);

        move_to(&container_signer, borrow_info);

        let loan_slot_obj = object::object_from_constructor_ref<LoanSlot>(&constructor_ref);
        object::transfer(borrower, loan_slot_obj, borrower_addr);

        // Emit event
        events::emit_loan_slot_created(
            object::object_address(&loan_slot_obj),
            borrower_addr,
            loan_pos_addr,
            principal,
            principal, // original_principal same as principal at creation
            share,
            reserve,
            debt_idx_at_borrow,
            ts
        );

        loan_slot_obj
    }

    public(friend) fun withdraw(
        borrower: &signer,
        ls_obj: Object<LoanSlot>,
        current_debt_idx: u128,
        amount: u64
    ): (u64, u64, bool, u128) acquires LoanSlot {
        assert_is_owner(borrower, ls_obj);
        assert_valid_debt_index(current_debt_idx);
        assert_non_zero_amount(amount);
        
        // Check active status BEFORE calling repay
        let loan_slot = borrow_loan_slot_mut(ls_obj);
        assert_is_active(loan_slot);

        let (principal_portion, interest_portion, loan_repaid, new_debt_idx) =
            repay(borrower, ls_obj, current_debt_idx, amount);

        // Re-borrow after repay since repay might have modified state
        let loan_slot = borrow_loan_slot_mut(ls_obj);
        
        // Only check principal_portion if loan is still active
        if (!loan_repaid) {
            assert_non_zero_principal(principal_portion);
        };

        // Calculate reserve proportional to original principal
        let reserve_to_withdraw = math128::mul_div(
            loan_slot.reserve as u128,
            principal_portion as u128,
            loan_slot.original_principal as u128
        ) as u64;

        loan_slot.withdrawn_amount += reserve_to_withdraw;
        loan_slot.available_withdraw = 
            if (loan_slot.available_withdraw >= reserve_to_withdraw) {
                loan_slot.available_withdraw - reserve_to_withdraw
            } else { 0 };

        // Emit event
        events::emit_loan_withdrawn(
            object::object_address(&ls_obj),
            signer::address_of(borrower),
            amount,
            reserve_to_withdraw,
            principal_portion,
            interest_portion,
            loan_slot.principal,
            loan_repaid,
            timestamp::now_seconds()
        );

        (reserve_to_withdraw, interest_portion, loan_repaid, new_debt_idx)
    }

    public(friend) fun repay(
        borrower: &signer,
        ls_obj: Object<LoanSlot>,
        current_debt_idx: u128,
        amount: u64
    ): (u64, u64, bool, u128) acquires LoanSlot {
        assert_is_owner(borrower, ls_obj);
        assert_valid_debt_index(current_debt_idx);

        let loan_slot = borrow_global_mut<LoanSlot>(object::object_address(&ls_obj));

        if (!loan_slot.active || amount == 0) {
            return (0, 0, false, current_debt_idx);
        };

        // Use original_principal for debt calculation consistency
        let principal_scaled = math128::mul_div(
            (loan_slot.original_principal as u128),
            current_debt_idx,
            loan_slot.debt_idx_at_borrow
        );
        
        let amount_u128 = amount as u128;
        // Correct logic for principal vs interest calculation
        let (principal_portion, interest_portion) = if (amount_u128 >= principal_scaled) {
            // Full repayment: pay all remaining principal + interest
            let interest = (principal_scaled - (loan_slot.principal as u128)) as u64;
            (loan_slot.principal, interest)
        } else {
            // Partial repayment: calculate how much goes to principal vs interest
            let principal_portion = math128::mul_div(
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

        // Don't modify debt index per loan slot - it should remain global
        // Debt index represents the global accumulated interest rate
        let new_debt_idx = current_debt_idx;

        // Emit event
        events::emit_loan_repaid(
            object::object_address(&ls_obj),
            signer::address_of(borrower),
            amount,
            principal_portion,
            interest_portion,
            loan_slot.principal,
            loan_repaid,
            new_debt_idx,
            loan_slot.last_payment_ts
        );

        (principal_portion, interest_portion, loan_repaid, new_debt_idx)
    }

    // === ASSERT FUNCTIONS ===
    fun assert_is_owner(signer: &signer, ls_obj: Object<LoanSlot>) {
        let signer_addr = signer::address_of(signer);
        assert!(
            object::is_owner(ls_obj, signer_addr),
            error::permission_denied(E_UNAUTHORIZED)
        );
    }

    fun assert_is_active(loan_slot: &LoanSlot) {
        assert!(loan_slot.active, E_NOT_ACTIVE);
    }

    fun assert_valid_amounts(principal: u64, share: u64, reserve: u64) {
        assert!(principal > 0, E_ZERO_AMOUNT);
        assert!(share > 0, E_ZERO_AMOUNT);
        assert!(reserve > 0, E_ZERO_AMOUNT);
    }

    fun assert_valid_debt_index(debt_idx: u128) {
        assert!(debt_idx >= PRECISION, E_INVALID_DEBT_INDEX);
    }

    fun assert_non_zero_amount(amount: u64) {
        assert!(amount > 0, E_ZERO_AMOUNT);
    }

    fun assert_non_zero_principal(principal: u64) {
        assert!(principal > 0, E_ZERO_PRINCIPAL);
    }

    fun assert_sufficient_reserve(loan_slot: &LoanSlot, required_amount: u64) {
        assert!(loan_slot.reserve >= required_amount, E_INSUFFICIENT_RESERVE);
    }

    // === SET FUNCTIONS ===
    public(friend) fun set_principal(ls_obj: Object<LoanSlot>, new_principal: u64) 
        acquires LoanSlot {
        let loan_slot = borrow_loan_slot_mut(ls_obj);
        loan_slot.principal = new_principal;
    }

    public(friend) fun set_share(ls_obj: Object<LoanSlot>, new_share: u64) 
        acquires LoanSlot {
        assert!(new_share > 0, E_ZERO_AMOUNT);
        let loan_slot = borrow_loan_slot_mut(ls_obj);
        loan_slot.share = new_share;
    }

    public(friend) fun set_reserve(ls_obj: Object<LoanSlot>, new_reserve: u64) 
        acquires LoanSlot {
        let loan_slot = borrow_loan_slot_mut(ls_obj);
        loan_slot.reserve = new_reserve;
    }

    public(friend) fun set_debt_idx_at_borrow(ls_obj: Object<LoanSlot>, new_debt_idx: u128) 
        acquires LoanSlot {
        assert_valid_debt_index(new_debt_idx);
        let loan_slot = borrow_loan_slot_mut(ls_obj);
        loan_slot.debt_idx_at_borrow = new_debt_idx;
    }

    public(friend) fun set_active_status(ls_obj: Object<LoanSlot>, is_active: bool) 
        acquires LoanSlot {
        let loan_slot = borrow_loan_slot_mut(ls_obj);
        loan_slot.active = is_active;
    }

    // === VIEW FUNCTIONS ===
    public fun principal(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).principal
    }

    public fun original_principal(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).original_principal
    }

    public fun share(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).share
    }

    public fun reserve(loan_slot_obj: Object<LoanSlot>): u64 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).reserve
    }

    public fun debt_idx_at_borrow(loan_slot_obj: Object<LoanSlot>): u128 acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).debt_idx_at_borrow
    }

    public fun is_active(loan_slot_obj: Object<LoanSlot>): bool acquires LoanSlot {
        borrow_loan_slot(loan_slot_obj).active
    }

    public fun current_debt(loan_slot_obj: Object<LoanSlot>, current_debt_idx: u128): u64 
        acquires LoanSlot {
        let loan_slot = borrow_loan_slot(loan_slot_obj);
        // Use original_principal for accurate debt calculation
        math128::mul_div(
            loan_slot.original_principal as u128,
            current_debt_idx,
            loan_slot.debt_idx_at_borrow
        ) as u64
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
}