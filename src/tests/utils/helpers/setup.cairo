use core::starknet::SyscallResultTrait;
use core::num::traits::Zero;
use starknet::{
    ClassHash, ContractAddress, contract_address_const, deploy_syscall,
    Felt252TryIntoContractAddress, get_contract_address, contract_address_try_from_felt252, testing,
    get_block_timestamp, testing::{set_block_timestamp, set_contract_address}
};
use openzeppelin_utils::serde::SerializedAppend;
use openzeppelin_token::erc20::{
    ERC20Component, interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait}
};
use pitch_lake::fossil_client::interface::{JobRequest, FossilResult, L1Data};
use pitch_lake::fossil_client::contract::FossilClient;
use pitch_lake::{
    library::eth::Eth, vault::contract::Vault,
    vault::interface::{ConstructorArgs, VaultType, IVaultDispatcher, IVaultDispatcherTrait},
    vault::contract::{Vault::{DAY}},
    option_round::{
        contract::OptionRound,
        interface::{
            PricingData, ConstructorArgs as ConstructorArgsOptionRound, IOptionRoundDispatcher,
            IOptionRoundDispatcherTrait, IOptionRoundSafeDispatcher,
            IOptionRoundSafeDispatcherTrait, OptionRoundState
        },
    },
    tests::{
        option_round::rb_tree::{
            rb_tree_mock_contract::{
                RBTreeMockContract, IRBTreeMockContractDispatcher,
                IRBTreeMockContractDispatcherTrait
            }
        },
        utils::{
            lib::{
                //structs::{OptionRoundParams},
                test_accounts::{weth_owner, liquidity_providers_get, option_bidders_get, bystander},
                variables::{week_duration, decimals},
            },
            helpers::{
                accelerators::{
                    accelerate_to_settled, accelerate_to_auctioning,
                    accelerate_to_auctioning_custom, accelerate_to_running
                },
                event_helpers::{clear_event_logs}, general_helpers::{to_wei},
            },
            facades::{
                option_round_facade::{OptionRoundFacade, OptionRoundFacadeTrait},
                vault_facade::{VaultFacade, VaultFacadeImpl, VaultFacadeTrait},
                fossil_client_facade::{FossilClientFacade, FossilClientFacadeTrait},
            },
        },
    },
};
use debug::PrintTrait;

const DECIMALS: u8 = 18_u8;
const SUPPLY: u256 = 99999999999999999999999999999999;

fn FOSSIL_PROCESSOR() -> ContractAddress {
    contract_address_const::<'FOSSIL PROCESSOR'>()
}

// Deploy eth contract for testing
fn deploy_eth() -> ERC20ABIDispatcher {
    let mut calldata = array![];

    calldata.append_serde(1000 * a_lot_of_eth());
    calldata.append_serde(weth_owner());

    let (contract_address, _): (ContractAddress, Span<felt252>) = deploy_syscall(
        Eth::TEST_CLASS_HASH.try_into().unwrap(), 'some salt', calldata.span(), false
    )
        .unwrap();

    // Clear the event log
    clear_event_logs(array![contract_address]);
    return ERC20ABIDispatcher { contract_address };
}

fn deploy_fossil_client() -> FossilClientFacade {
    let mut calldata = array![];
    calldata.append_serde(FOSSIL_PROCESSOR());
    let (contract_address, _): (ContractAddress, Span<felt252>) = deploy_syscall(
        FossilClient::TEST_CLASS_HASH.try_into().unwrap(), 'some salt', calldata.span(), false
    )
        .expect('DEPLOY_FOSSIL_CLIENT_FAILED');

    // Clear the event log (not needed)
    clear_event_logs(array![contract_address]);

    return FossilClientFacade { contract_address };
}


// Deploy the vault and fossil client
fn deploy_vault_with_events(
    vault_type: VaultType, eth_address: ContractAddress
) -> IVaultDispatcher {
    /// Deploy Vault
    let mut calldata = array![];
    let args = ConstructorArgs {
        fossil_client_address: deploy_fossil_client().contract_address,
        eth_address,
        option_round_class_hash: OptionRound::TEST_CLASS_HASH.try_into().unwrap(),
        vault_type,
    };
    args.serialize(ref calldata);

    // @dev Making salt timestamp dependent so we can easily deploy new instances for testing
    let now = get_block_timestamp();
    let salt = 'some salt' + now.into();

    let (contract_address, _) = deploy_syscall(
        Vault::TEST_CLASS_HASH.try_into().unwrap(), salt, calldata.span(), true
    )
        .expect('DEPLOY_VAULT_FAILED');

    return IVaultDispatcher { contract_address };
}

// Deploy the vault and fossil client with events cleared
fn deploy_vault(vault_type: VaultType, eth_address: ContractAddress) -> IVaultDispatcher {
    let vault = deploy_vault_with_events(vault_type, eth_address);

    // Clear the event log
    clear_event_logs(array![vault.contract_address]);

    vault
}

fn setup_rb_tree_test() -> IRBTreeMockContractDispatcher {
    let (address, _) = deploy_syscall(
        RBTreeMockContract::TEST_CLASS_HASH.try_into().unwrap(), 0, array![].span(), false
    )
        .unwrap_syscall();
    IRBTreeMockContractDispatcher { contract_address: address }
}

fn to_gwei(amount: u256) -> u256 {
    amount * 1_000_000_000
}

fn setup_facade_vault_type(vault_type: VaultType) -> VaultFacade {
    set_block_timestamp(1234567890);

    // Deploy eth
    let eth_dispatcher: ERC20ABIDispatcher = deploy_eth();

    // Deploy vault facade
    let vault_dispatcher: IVaultDispatcher = deploy_vault(
        vault_type, eth_dispatcher.contract_address
    );
    let mut vault_facade = VaultFacade { vault_dispatcher };

    // Fulfill request to start auction
    let mut serialized_request = array![];
    let mut serialized_result = array![];
    vault_facade.get_request_to_start_auction().serialize(ref serialized_request);
    FossilResult {
        l1_data: L1Data { twap: to_gwei(10), volatility: 5000, reserve_price: to_gwei(2), },
        proof: array!['doesnt', 'matter'].span()
    }
        .serialize(ref serialized_result);

    vault_facade
        .get_fossil_client_facade()
        .fossil_callback(serialized_request.span(), serialized_result.span());

    // @dev Supply eth to liquidity providers and approve vault for transferring eth
    eth_supply_and_approve_all_providers(
        vault_dispatcher.contract_address, eth_dispatcher.contract_address
    );

    // @dev Supply eth to option buyers and approve current round for transferring eth
    let current_round_address = vault_dispatcher
        .get_round_address(vault_dispatcher.get_current_round_id());
    eth_supply_and_approve_all_bidders(current_round_address, eth_dispatcher.contract_address);

    // Clear eth transfer events
    clear_event_logs(
        array![
            eth_dispatcher.contract_address, vault_facade.contract_address(), current_round_address
        ]
    );

    return vault_facade;
}

fn setup_facade() -> (VaultFacade, ERC20ABIDispatcher) {
    let mut vault_facade = setup_facade_vault_type(VaultType::AtTheMoney);
    let eth_dispatcher = ERC20ABIDispatcher { contract_address: vault_facade.get_eth_address() };

    (vault_facade, eth_dispatcher)
}

fn setup_test_auctioning_bidders(
    number_of_option_buyers: u32
) -> (VaultFacade, ERC20ABIDispatcher, Span<ContractAddress>, u256) {
    let (mut vault, eth) = setup_facade();

    // Auction participants
    let mut option_bidders = option_bidders_get(number_of_option_buyers);

    // Start auction
    let total_options_available = accelerate_to_auctioning(ref vault);

    (vault, eth, option_bidders.span(), total_options_available)
}

fn setup_test_running() -> (VaultFacade, OptionRoundFacade) {
    let (mut vault, _) = setup_facade();
    let mut current_round = vault.get_current_round();

    accelerate_to_auctioning(ref vault);
    accelerate_to_running(ref vault);

    (vault, current_round)
}

fn setup_test_auctioning_providers(
    number_of_option_buyers: u32, deposit_amounts: Span<u256>
) -> (VaultFacade, ERC20ABIDispatcher, Span<ContractAddress>, u256) {
    let (mut vault, eth) = setup_facade();
    let mut liquidity_providers = liquidity_providers_get(number_of_option_buyers).span();
    // Amounts to deposit: [100, 200, 300, 400]
    let total_options_available = accelerate_to_auctioning_custom(
        ref vault, liquidity_providers, deposit_amounts
    );
    (vault, eth, liquidity_providers, total_options_available)
}

//Eth setup helpers

fn eth_supply_and_approve_all(
    contract_address: ContractAddress,
    eth_address: ContractAddress,
    addresses: Span<ContractAddress>
) {
    eth_supply(eth_address, addresses);
    eth_approval(contract_address, eth_address, addresses);
}
fn eth_supply_and_approve_all_providers(
    contract_address: ContractAddress, eth_address: ContractAddress
) {
    let mut liquidity_providers = liquidity_providers_get(6);
    eth_supply_and_approve_all(contract_address, eth_address, liquidity_providers.span());
}

fn eth_supply_and_approve_all_bidders(
    contract_address: ContractAddress, eth_address: ContractAddress
) {
    let option_biddders = option_bidders_get(6);
    eth_supply_and_approve_all(contract_address, eth_address, option_biddders.span());
}

fn a_lot_of_eth() -> u256 {
    decimals() * decimals() * decimals() //10^36 ETH
}

fn eth_supply(eth_address: ContractAddress, mut receivers: Span<ContractAddress>) {
    let eth_dispatcher = ERC20ABIDispatcher { contract_address: eth_address };
    loop {
        match receivers.pop_front() {
            Option::Some(receiver) => {
                set_contract_address(weth_owner());
                let ob_amount_wei: u256 = a_lot_of_eth();

                eth_dispatcher.transfer(*receiver, ob_amount_wei);
            },
            Option::None => { break; },
        };
    };
}
fn eth_approval(
    contract_address: ContractAddress,
    eth_address: ContractAddress,
    mut approvers: Span<ContractAddress>
) {
    let eth_dispatcher = ERC20ABIDispatcher { contract_address: eth_address };
    loop {
        match approvers.pop_front() {
            Option::Some(approver) => {
                set_contract_address(weth_owner());
                let ob_amount_wei: u256 = a_lot_of_eth();

                //Debug
                // let felt_ca: felt252 = contract_address.into();
                // let felt_eth: felt252 = eth_address.into();
                // let app: ContractAddress = *approver;
                // let felt_app: felt252 = app.into();

                set_contract_address(*approver);
                eth_dispatcher.approve(contract_address, ob_amount_wei);
            },
            Option::None => { break; },
        };
    };
}
