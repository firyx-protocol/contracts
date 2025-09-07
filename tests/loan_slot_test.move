// module fered::test_loan_slot {
//     use std::signer;
//     use aptos_framework::aptos_coin;
//     use aptos_framework::object::{Self, Object};
//     use aptos_framework::timestamp;
//     use aptos_framework::math128;
//     use fered::loan_slot::{Self, LoanSlot};
//     use fered::math::{bps};

//     // Test helper function
//     #[test_only]
//     fun init_for_test(deployer: &signer, aptos_framework: &signer) {
//         aptos_coin::ensure_initialized_with_apt_fa_metadata_for_test();
//         timestamp::set_time_has_started_for_testing(aptos_framework);
//         loan_slot::init_module_f(deployer);
//     }

//     // === CREATION TESTS ===

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_create_loan_slot_basic(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_slot_addr = @0x456;
//         let principal = 1000u64;
//         let collateral = 2000u64;
//         let debt_idx = 1000000000000u128;
        
//         let loan_obj = loan_slot::create_loan_slot(
//             borrower, 
//             loan_slot_addr, 
//             principal, 
//             collateral, 
//             debt_idx
//         );
        
//         // Verify loan slot properties
//         assert!(loan_slot::principal(loan_obj) == principal, 1);
//         assert!(loan_slot::collateral(loan_obj) == collateral, 2);
//         assert!(loan_slot::debt_idx_at_borrow(loan_obj) == debt_idx, 3);
//         assert!(loan_slot::is_active(loan_obj), 4);
//         assert!(!loan_slot::is_liquidated(loan_obj), 5);
//         assert!(loan_slot::withdrawn_amount(loan_obj) == principal, 6);
//         assert!(loan_slot::available_withdraw(loan_obj) == 0, 7);
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_create_multiple_loan_slots(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         // Create first loan slot
//         let loan1 = loan_slot::create_loan_slot(borrower, @0x111, 500, 1000, 1000000000000);
//         // Create second loan slot
//         let loan2 = loan_slot::create_loan_slot(borrower, @0x222, 1500, 3000, 1200000000000);
        
//         // Verify both exist and have correct values
//         assert!(loan_slot::principal(loan1) == 500, 1);
//         assert!(loan_slot::principal(loan2) == 1500, 2);
//         assert!(loan_slot::collateral(loan1) == 1000, 3);
//         assert!(loan_slot::collateral(loan2) == 3000, 4);
//     }

//     // === WITHDRAWAL TESTS ===

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_withdraw_success(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
        
//         // Manually set available_withdraw for testing
//         // In real scenario, this would be set by yield earning logic
//         loan_slot::set_available_withdraw(loan_obj, 500);
        
//         let withdrawn = loan_slot::withdraw(borrower, loan_obj, 300);
        
//         assert!(withdrawn == 300, 1);
//         assert!(loan_slot::withdrawn_amount(loan_obj) == 1300, 2);
//         assert!(loan_slot::available_withdraw(loan_obj) == 200, 3);
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123, other = @0x999)]
//     #[expected_failure(abort_code = 0x50002)] // E_UNAUTHORIZED
//     fun test_withdraw_unauthorized(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer,
//         other: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
//         loan_slot::set_available_withdraw(loan_obj, 500);
        
//         // Other user tries to withdraw - should fail
//         loan_slot::withdraw(other, loan_obj, 100);
//     }

//     // === REPAYMENT TESTS ===

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_partial_repayment(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
//         let current_debt_idx = 1200000000000u128; // 20% interest accrued
        
//         let (principal_portion, interest_portion, loan_repaid, new_debt_idx) = 
//             loan_slot::repay(borrower, loan_obj, current_debt_idx, 500);
        
//         // Should repay 416 principal and 84 interest (approximately)
//         assert!(principal_portion > 400 && principal_portion < 450, 1);
//         assert!(interest_portion > 50 && interest_portion < 100, 2);
//         assert!(!loan_repaid, 3);
//         assert!(loan_slot::principal(loan_obj) < 1000, 4);
//         assert!(loan_slot::is_active(loan_obj), 5);
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_full_repayment(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
//         let current_debt_idx = 1200000000000u128;
        
//         // Repay more than enough to cover full debt
//         let (principal_portion, interest_portion, loan_repaid, _) = 
//             loan_slot::repay(borrower, loan_obj, current_debt_idx, 1500);
        
//         assert!(principal_portion == 1000, 1);
//         assert!(interest_portion == 200, 2); // 20% interest
//         assert!(loan_repaid, 3);
//         assert!(loan_slot::principal(loan_obj) == 0, 4);
//         assert!(!loan_slot::is_active(loan_obj), 5);
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_repay_inactive_loan(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
        
//         // First repay fully to make loan inactive
//         loan_slot::repay(borrower, loan_obj, 1200000000000, 1500);
        
//         // Try to repay again - should return zeros
//         let (principal_portion, interest_portion, loan_repaid, debt_idx) = 
//             loan_slot::repay(borrower, loan_obj, 1200000000000, 100);
        
//         assert!(principal_portion == 0, 1);
//         assert!(interest_portion == 0, 2);
//         assert!(!loan_repaid, 3);
//     }

//     // === LIQUIDATION TESTS ===

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123, liquidator = @0x999)]
//     fun test_liquidation_success(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer,
//         liquidator: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 1200, 1000000000000);
//         // High debt index to trigger liquidation (debt grows to make LTV > threshold)
//         let high_debt_idx = 2000000000000u128; // 100% increase
//         let liquidation_threshold = 8500u64; // 85%
        
//         let (liquidated, bonus, protocol_fee, remaining) = 
//             loan_slot::liquidate(liquidator, loan_obj, high_debt_idx, liquidation_threshold);
        
//         assert!(liquidated, 1);
//         assert!(bonus == 60, 2); // 5% of 1200 collateral
//         assert!(protocol_fee == 12, 3); // 1% of 1200 collateral
//         assert!(remaining == 1128, 4); // 1200 - 60 - 12
//         assert!(!loan_slot::is_active(loan_obj), 5);
//         assert!(loan_slot::is_liquidated(loan_obj), 6);
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123, liquidator = @0x999)]
//     fun test_liquidation_healthy_loan(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer,
//         liquidator: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 3000, 1000000000000);
//         let normal_debt_idx = 1100000000000u128; // 10% increase
//         let liquidation_threshold = 8500u64;
        
//         let (liquidated, bonus, protocol_fee, remaining) = 
//             loan_slot::liquidate(liquidator, loan_obj, normal_debt_idx, liquidation_threshold);
        
//         // Should not liquidate healthy loan
//         assert!(!liquidated, 1);
//         assert!(bonus == 0, 2);
//         assert!(protocol_fee == 0, 3);
//         assert!(remaining == 0, 4);
//         assert!(loan_slot::is_active(loan_obj), 5);
//         assert!(!loan_slot::is_liquidated(loan_obj), 6);
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123, liquidator = @0x999)]
//     fun test_liquidation_already_liquidated(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer,
//         liquidator: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 1200, 1000000000000);
//         let high_debt_idx = 2000000000000u128;
//         let liquidation_threshold = 8500u64;
        
//         // First liquidation
//         loan_slot::liquidate(liquidator, loan_obj, high_debt_idx, liquidation_threshold);
        
//         // Try to liquidate again
//         let (liquidated, bonus, protocol_fee, remaining) = 
//             loan_slot::liquidate(liquidator, loan_obj, high_debt_idx, liquidation_threshold);
        
//         assert!(!liquidated, 1);
//         assert!(bonus == 0, 2);
//         assert!(protocol_fee == 0, 3);
//         assert!(remaining == 0, 4);
//     }

//     // === VIEW FUNCTION TESTS ===

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_view_functions(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_addr = @0x456;
//         let principal = 1000u64;
//         let collateral = 2000u64;
//         let debt_idx = 1500000000000u128;
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, loan_addr, principal, collateral, debt_idx);
        
//         // Test basic getters
//         assert!(loan_slot::loan_slot_address(loan_obj) == loan_addr, 1);
//         assert!(loan_slot::principal(loan_obj) == principal, 2);
//         assert!(loan_slot::collateral(loan_obj) == collateral, 3);
//         assert!(loan_slot::debt_idx_at_borrow(loan_obj) == debt_idx, 4);
        
//         // Test status functions
//         assert!(loan_slot::is_active(loan_obj), 5);
//         assert!(!loan_slot::is_liquidated(loan_obj), 6);
        
//         // Test calculated functions
//         let current_debt_idx = 1800000000000u128; // 20% increase from borrow
//         let debt = loan_slot::current_debt(loan_obj, current_debt_idx);
//         let expected_debt = math128::mul_div(principal as u128, current_debt_idx, debt_idx) as u64;
//         assert!(debt == expected_debt, 7);
        
//         let ltv = loan_slot::current_ltv(loan_obj, current_debt_idx);
//         let expected_ltv = math128::mul_div(debt as u128, bps() as u128, collateral as u128) as u64;
//         assert!(ltv == expected_ltv, 8);
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_timestamp_functions(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let start_time = timestamp::now_seconds();
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
        
//         assert!(loan_slot::timestamp_created(loan_obj) >= start_time, 1);
//         assert!(loan_slot::last_payment_timestamp(loan_obj) >= start_time, 2);
        
//         // Test payment timestamp update
//         timestamp::fast_forward_seconds(100);
//         loan_slot::repay(borrower, loan_obj, 1100000000000, 100);
        
//         let new_payment_time = loan_slot::last_payment_timestamp(loan_obj);
//         assert!(new_payment_time > start_time, 3);
//     }

//     // === EDGE CASE TESTS ===

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_zero_amount_repayment(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
        
//         let (principal_portion, interest_portion, loan_repaid, _) = 
//             loan_slot::repay(borrower, loan_obj, 1200000000000, 0);
        
//         assert!(principal_portion == 0, 1);
//         assert!(interest_portion == 0, 2);
//         assert!(!loan_repaid, 3);
//         assert!(loan_slot::principal(loan_obj) == 1000, 4); // Unchanged
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_high_precision_calculations(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         // Test with very small principal and large debt index changes
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1, 1000000, 1000000000000);
//         let high_debt_idx = 5000000000000u128; // 5x increase
        
//         let debt = loan_slot::current_debt(loan_obj, high_debt_idx);
//         assert!(debt == 5, 1); // 1 * 5 = 5
        
//         let ltv = loan_slot::current_ltv(loan_obj, high_debt_idx);
//         assert!(ltv == 0, 2); // Very small LTV due to large collateral
//     }

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123)]
//     fun test_maximum_values(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         // Test with maximum u64 values
//         let max_u64 = 18446744073709551615u64;
//         let loan_obj = loan_slot::create_loan_slot(
//             borrower, 
//             @0x456, 
//             max_u64, 
//             max_u64, 
//             1000000000000u128
//         );
        
//         assert!(loan_slot::principal(loan_obj) == max_u64, 1);
//         assert!(loan_slot::collateral(loan_obj) == max_u64, 2);
//     }

//     // === COMPLEX SCENARIO TESTS ===

//     #[test(fered = @fered, aptos_framework = @0x1, borrower = @0x123, liquidator = @0x999)]
//     fun test_loan_lifecycle(
//         fered: &signer,
//         aptos_framework: &signer,
//         borrower: &signer,
//         liquidator: &signer
//     ) {
//         init_for_test(fered, aptos_framework);
        
//         // Create loan
//         let loan_obj = loan_slot::create_loan_slot(borrower, @0x456, 1000, 2000, 1000000000000);
        
//         // Make partial repayment
//         let debt_idx_1 = 1100000000000u128;
//         let (p1, i1, repaid1, _) = loan_slot::repay(borrower, loan_obj, debt_idx_1, 300);
//         assert!(!repaid1, 1);
//         assert!(p1 + i1 == 300, 2);
        
//         // Time passes, debt grows
//         let debt_idx_2 = 1300000000000u128;
        
//         // Try liquidation (should fail - healthy)
//         let (liquidated1, _, _, _) = loan_slot::liquidate(liquidator, loan_obj, debt_idx_2, 8500);
//         assert!(!liquidated1, 3);
        
//         // More time passes, debt grows significantly
//         let debt_idx_3 = 2500000000000u128;
        
//         // Liquidation should succeed now
//         let (liquidated2, bonus, fee, remaining) = 
//             loan_slot::liquidate(liquidator, loan_obj, debt_idx_3, 8500);
//         assert!(liquidated2, 4);
//         assert!(bonus > 0, 5);
//         assert!(fee > 0, 6);
//         assert!(remaining > 0, 7);
//         assert!(!loan_slot::is_active(loan_obj), 8);
//         assert!(loan_slot::is_liquidated(loan_obj), 9);
//     }
// }