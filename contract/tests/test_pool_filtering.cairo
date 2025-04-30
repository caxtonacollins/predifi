// Import the contract types and interface
use contract::base::types::{Category, Pool, PoolDetails, Status};
use contract::interfaces::ipredifi::{IPredifiDispatcher, IPredifiDispatcherTrait};
use core::traits::Into;
use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_caller_address, stop_cheat_block_timestamp,
};
use starknet::{ContractAddress, contract_address_const, get_block_timestamp};

const POOL_CREATOR: ContractAddress = 123.try_into().unwrap();

// Helper function to deploy the Predifi contract
fn setup() -> (
    ContractAddress, ContractAddress, ContractAddress, IPredifiDispatcher, IERC20Dispatcher,
) {
    // Deploy mock ERC20
    let owner: ContractAddress = contract_address_const::<'owner'>();
    let admin: ContractAddress = contract_address_const::<'admin'>();
    let validator: ContractAddress = contract_address_const::<'validator'>();

    let erc20_class = declare("STARKTOKEN").unwrap().contract_class();
    let mut calldata = array![POOL_CREATOR.into(), owner.into(), 6];
    let (erc20_address, _) = erc20_class.deploy(@calldata).unwrap();
    let erc20_dispatcher: IERC20Dispatcher = IERC20Dispatcher {
        contract_address: erc20_address,
    };

    // Declare Predifi the contract
    let contract_class = declare("Predifi").unwrap().contract_class();

    // Create constructor calldata
    let mut constructor_calldata = array![erc20_address.into(), admin.into(), validator.into()];

    // Deploy Predifi the contract
    let (predifi_address, _) = contract_class.deploy(@constructor_calldata).unwrap();

    // Create dispatcher
    let predifi_dispatcher = IPredifiDispatcher { contract_address: predifi_address };

    (predifi_address, erc20_address, POOL_CREATOR, predifi_dispatcher, erc20_dispatcher)
}

// Helper function to create a test pool
fn create_test_pool(
    dispatcher: IPredifiDispatcher,
    poolName: felt252,
    poolStartTime: u64,
    poolLockTime: u64,
    poolEndTime: u64,
) -> u256 {
    dispatcher
        .create_pool(
            poolName,
            Pool::WinBet,
            "Test Description",
            "Test Image",
            "Test URL",
            poolStartTime,
            poolLockTime,
            poolEndTime,
            'Option 1',
            'Option 2',
            100_u256,
            1000_u256,
            5,
            false,
            Category::Sports,
        )
}

fn pool_exists_in_array(pools: Array<PoolDetails>, pool_id: u256) -> bool {
    let mut i = 0;
    let len = pools.len();

    loop {
        if i >= len {
            break false;
        }

        let pool = pools.at(i);
        // Use the correct reference type for comparison
        if *pool.pool_id == pool_id {
            break true;
        }

        i += 1;
    }
}

#[test]
fn test_minimal_timing() {
    let (_, erc20_address, POOL_CREATOR, dispatcher, erc20_dispatcher) = setup();

    start_cheat_caller_address(erc20_address, POOL_CREATOR);
    erc20_dispatcher.approve(dispatcher.contract_address, 200_000_000_000_000_000_000_000);
    stop_cheat_caller_address(erc20_address);

    let t0 = 1000;
    start_cheat_block_timestamp(dispatcher.contract_address, t0);

    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool_id = create_test_pool(
        dispatcher, 'Test Pool', t0 + 1000, // 2000
        t0 + 2000, // 3000
        t0 + 3000 // 4000
    );
    stop_cheat_caller_address(dispatcher.contract_address);
}

#[test]
fn test_get_active_pools() {
    // Deploy the contract
    let (_, erc20_address, POOL_CREATOR, dispatcher, erc20_dispatcher) = setup();

    // Approve the dispatcher contract to spend tokens
    start_cheat_caller_address(erc20_address, POOL_CREATOR);
    erc20_dispatcher.approve(dispatcher.contract_address, 200_000_000_000_000_000_000_000);
    stop_cheat_caller_address(erc20_address);

    // Set initial block timestamp
    let initial_time = 1000;
    start_cheat_block_timestamp(dispatcher.contract_address, initial_time);

    // Impersonate POOL_CREATOR for pool creation
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool1_id = create_test_pool(
        dispatcher,
        'Active Pool 1',
        initial_time + 1600,
        initial_time + 2000,
        initial_time + 3000,
    );
    stop_cheat_caller_address(dispatcher.contract_address);

    let time_2 = initial_time + 1000;
    stop_cheat_block_timestamp(dispatcher.contract_address);
    start_cheat_block_timestamp(dispatcher.contract_address, time_2);

    // Impersonate POOL_CREATOR for pool creation
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool2_id = create_test_pool(
        dispatcher, 'Active Pool 2', time_2 + 500, time_2 + 1500, time_2 + 3500,
    );
    stop_cheat_caller_address(dispatcher.contract_address);

    // Advance time to 3500 (after both pools' start, before both pools' lock)
    stop_cheat_block_timestamp(dispatcher.contract_address);
    let active_time = 1500;
    start_cheat_block_timestamp(dispatcher.contract_address, active_time);

    // Update pool states before checking
    dispatcher.update_pool_state(pool1_id);
    dispatcher.update_pool_state(pool2_id);

    // Get active pools
    let active_pools = dispatcher.get_active_pools();

    // Debug: check pool statuses
    let pool1 = dispatcher.get_pool(pool1_id);
    let pool2 = dispatcher.get_pool(pool2_id);

    assert(pool1.status == Status::Active, 'Pool 1 should be active');
    assert(pool2.status == Status::Active, 'Pool 2 should be active');

    // Verify we have 2 active pools
    assert(active_pools.len() == 2, 'Expected 2 active pools');

    // Clean up
    stop_cheat_block_timestamp(dispatcher.contract_address);
}

#[test]
fn test_get_locked_pools() {
    let (_, erc20_address, POOL_CREATOR, dispatcher, erc20_dispatcher) = setup();

    start_cheat_caller_address(erc20_address, POOL_CREATOR);
    erc20_dispatcher.approve(dispatcher.contract_address, 200_000_000_000_000_000_000_000);
    stop_cheat_caller_address(erc20_address);

    let initial_time = 1000;
    start_cheat_block_timestamp(dispatcher.contract_address, initial_time);

    // Pool 1
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool1_id = create_test_pool(
        dispatcher,
        'Locked Pool 1',
        initial_time + 1000, // start: 2000
        initial_time + 2000, // lock: 3000
        initial_time + 3000 // end: 4000
    );
    stop_cheat_caller_address(dispatcher.contract_address);
    stop_cheat_block_timestamp(dispatcher.contract_address);

    // Set block timestamp for Pool 2 creation
    let time_2 = initial_time + 1000;
    start_cheat_block_timestamp(dispatcher.contract_address, time_2);

    // Pool 2 (start time strictly greater than block timestamp)
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool2_id = create_test_pool(
        dispatcher,
        'Locked Pool 2',
        time_2 + 1, // start: 2001
        time_2 + 1001, // lock: 3001
        time_2 + 2001 // end: 4001
    );
    stop_cheat_caller_address(dispatcher.contract_address);
    stop_cheat_block_timestamp(dispatcher.contract_address);

    // Advance time to just after both locks but before both ends
    let locked_time = time_2 + 1200; // 2200 > 2001 (lock), < 4001 (end)
    start_cheat_block_timestamp(dispatcher.contract_address, locked_time);

    dispatcher.update_pool_state(pool1_id);
    dispatcher.update_pool_state(pool2_id);

    let locked_pools = dispatcher.get_locked_pools();
    let pool1 = dispatcher.get_pool(pool1_id);
    let pool2 = dispatcher.get_pool(pool2_id);

    assert(pool1.status == Status::Locked, 'Pool 1 should be locked');
    assert(pool2.status == Status::Locked, 'Pool 2 should be locked');
    assert(locked_pools.len() == 2, 'Expected 2 locked pools');
    stop_cheat_block_timestamp(dispatcher.contract_address);
}

#[test]
fn test_get_settled_pools() {
    let (_, erc20_address, POOL_CREATOR, dispatcher, erc20_dispatcher) = setup();

    start_cheat_caller_address(erc20_address, POOL_CREATOR);
    erc20_dispatcher.approve(dispatcher.contract_address, 200_000_000_000_000_000_000_000);
    stop_cheat_caller_address(erc20_address);

    let initial_time = 1000;
    start_cheat_block_timestamp(dispatcher.contract_address, initial_time);

    // Pool 1
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool1_id = create_test_pool(
        dispatcher,
        'Settled Pool 1',
        initial_time + 1000, // start: 2000
        initial_time + 2000, // lock: 3000
        initial_time + 3000 // end: 4000
    );
    stop_cheat_caller_address(dispatcher.contract_address);
    stop_cheat_block_timestamp(dispatcher.contract_address);

    // Set block timestamp for Pool 2 creation
    let time_2 = initial_time + 1500; // 2500
    start_cheat_block_timestamp(dispatcher.contract_address, time_2);

    // Pool 2 (start time strictly greater than block timestamp)
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool2_id = create_test_pool(
        dispatcher,
        'Settled Pool 2',
        time_2 + 100, // start: 2600
        time_2 + 1100, // lock: 3600
        time_2 + 2100 // end: 4600
    );
    stop_cheat_caller_address(dispatcher.contract_address);
    stop_cheat_block_timestamp(dispatcher.contract_address);

    // Advance time to after both ends
    let settled_time = initial_time + 5000; // 5000 > 4000 and 4600
    start_cheat_block_timestamp(dispatcher.contract_address, settled_time);

    dispatcher.update_pool_state(pool1_id);
    dispatcher.update_pool_state(pool2_id);

    let settled_pools = dispatcher.get_settled_pools();
    let pool1 = dispatcher.get_pool(pool1_id);
    let pool2 = dispatcher.get_pool(pool2_id);
    assert(pool1.status == Status::Settled, 'Pool 1 should be settled');
    assert(pool2.status == Status::Settled, 'Pool 2 should be settled');
    assert(settled_pools.len() == 2, 'Expected 2 settled pools');
    stop_cheat_block_timestamp(dispatcher.contract_address);
}

#[test]
fn test_get_closed_pools() {
    let (_, erc20_address, POOL_CREATOR, dispatcher, erc20_dispatcher) = setup();

    start_cheat_caller_address(erc20_address, POOL_CREATOR);
    erc20_dispatcher.approve(dispatcher.contract_address, 200_000_000_000_000_000_000_000);
    stop_cheat_caller_address(erc20_address);

    let initial_time = 1000;
    start_cheat_block_timestamp(dispatcher.contract_address, initial_time);

    // Pool 1
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool1_id = create_test_pool(
        dispatcher,
        'Closed Pool 1',
        initial_time + 1000, // start: 2000
        initial_time + 2000, // lock: 3000
        initial_time + 3000 // end: 4000
    );
    stop_cheat_caller_address(dispatcher.contract_address);
    stop_cheat_block_timestamp(dispatcher.contract_address);

    // Set block timestamp for Pool 2 creation
    let time_2 = initial_time + 1500; // 2500
    start_cheat_block_timestamp(dispatcher.contract_address, time_2);

    // Pool 2 (start time strictly greater than block timestamp)
    start_cheat_caller_address(dispatcher.contract_address, POOL_CREATOR);
    let pool2_id = create_test_pool(
        dispatcher,
        'Closed Pool 2',
        time_2 + 100, // start: 2600
        time_2 + 1100, // lock: 3600
        time_2 + 2100 // end: 4600
    );
    stop_cheat_caller_address(dispatcher.contract_address);
    stop_cheat_block_timestamp(dispatcher.contract_address);

    // Assume pool1_id and pool2_id are created, and you have their end times
    let end_time_1 = 4000; // set to pool 1's end time
    let end_time_2 = 4600; // set to pool 2's end time
    let after_end = core::cmp::max(end_time_1, end_time_2) + 1;
    start_cheat_block_timestamp(dispatcher.contract_address, after_end);
    dispatcher.update_pool_state(pool1_id);
    dispatcher.update_pool_state(pool2_id);
    stop_cheat_block_timestamp(dispatcher.contract_address);

    // Now advance to after end_time + 86401 for the latest pool
    let after_closed = core::cmp::max(end_time_1, end_time_2) + 86401;
    start_cheat_block_timestamp(dispatcher.contract_address, after_closed);
    dispatcher.update_pool_state(pool1_id);
    dispatcher.update_pool_state(pool2_id);

    let closed_pools = dispatcher.get_closed_pools();
    let pool1 = dispatcher.get_pool(pool1_id);
    let pool2 = dispatcher.get_pool(pool2_id);
    println!("Pool 1 status: {:?}", pool1.status);
    println!("Pool 2 status: {:?}", pool2.status);
    println!("closed_pools.len(): {:?}", closed_pools.len());
    assert(pool1.status == Status::Closed, 'Pool 1 should be closed');
    assert(pool2.status == Status::Closed, 'Pool 2 should be closed');
    assert(closed_pools.len() == 2, 'Expected 2 closed pools');
}
