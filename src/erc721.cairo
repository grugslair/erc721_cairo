use starknet::ContractAddress;

#[starknet::interface]
trait IERC721<TContractState> {
    fn get_name(self: @TContractState) -> felt252;
    fn get_symbol(self: @TContractState) -> felt252;
    fn token_uri(self: @TContractState, token_id: u256) -> felt252;
    fn balance_of(self: @TContractState, account: ContractAddress) -> u256;
    fn is_approved_for_all(
        self: @TContractState, owner: ContractAddress, operator: ContractAddress
    ) -> bool;

    fn total_supply(self: @TContractState) -> u256;
    fn max_supply(self: @TContractState) -> u256;
    
    fn get_free_mint_start_time(self: @TContractState) -> u64;
    fn get_mint_end_time(self: @TContractState) -> u64;

    fn register_whitelist(ref self: TContractState, account: ContractAddress, amount: u256);

    fn is_free_mint_active(self: @TContractState) -> bool;
    // fn is_paid_mint_active(self: @TContractState) -> bool;
    fn check_free_mint(self: @TContractState, account: ContractAddress) -> u256;

    fn set_base_uri(ref self: TContractState, base_uri: felt252);

    fn owner_of(self: @TContractState, token_id: u256) -> ContractAddress;
    fn get_approved(self: @TContractState, token_id: u256) -> ContractAddress;

    fn set_approval_for_all(ref self: TContractState, operator: ContractAddress, approved: bool);
    fn approve(ref self: TContractState, to: ContractAddress, token_id: u256);
    fn transfer_from(
        ref self: TContractState, from: ContractAddress, to: ContractAddress, token_id: u256
    );
    fn mint(ref self: TContractState, amount: u256);
}

#[starknet::contract]
mod ERC721 {
    use starknet::get_caller_address;
    use starknet::get_block_timestamp;
    use starknet::contract_address_const;
    use starknet::ContractAddress;
    use traits::Into;
    use zeroable::Zeroable;
    use traits::TryInto;
    use array::SpanTrait;
    use array::ArrayTrait;
    use array::ArrayTCloneImpl;
    use option::OptionTrait;

    use super::super::erc721_receiver::ERC721Receiver;
    use super::super::erc721_receiver::ERC721ReceiverTrait;

    const FREE_MINT_DURATION: u64 = 86400_u64;
    // const PAID_MINT_DURATION: u64 = 86400_u64;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        owners: LegacyMap::<u256, ContractAddress>,
        balances: LegacyMap::<ContractAddress, u256>,
        token_approvals: LegacyMap::<u256, ContractAddress>,
        total_supply: u256,
        max_supply: u256,
        base_uri: felt252,
        free_mint: LegacyMap::<ContractAddress, u256>,
        operator_approvals: LegacyMap::<(ContractAddress, ContractAddress), bool>,
        free_mint_start_time: u64,
        // paid_mint_start_time: u64,
        mint_end_time: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Approval: Approval,
        Transfer: Transfer,
        ApprovalForAll: ApprovalForAll,
    }
    #[derive(Drop, starknet::Event)]
    struct Approval {
        owner: ContractAddress,
        to: ContractAddress,
        token_id: u256
    }
    #[derive(Drop, starknet::Event)]
    struct Transfer {
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256
    }
    #[derive(Drop, starknet::Event)]
    struct ApprovalForAll {
        owner: ContractAddress,
        operator: ContractAddress,
        approved: bool
    }

    #[constructor]
    fn constructor(ref self: ContractState, _name: felt252, _symbol: felt252, _max_supply: u256) {
        self.name.write(_name);
        self.symbol.write(_symbol);
        self.max_supply.write(_max_supply);
        self.free_mint_start_time.write(get_block_timestamp());
        self.mint_end_time.write(self.free_mint_start_time.read() + FREE_MINT_DURATION)

        // let paid_mint_time: u64 = current_time + FREE_MINT_DURATION;
        // paid_mint_start_time::write(paid_mint_time);

    }

    #[abi(embed_v0)]
    impl IERC721Impl of super::IERC721<ContractState> {
        fn get_name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn get_symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn get_free_mint_start_time(self: @ContractState) -> u64 {
            self.free_mint_start_time.read()
        }

        fn get_mint_end_time(self: @ContractState) -> u64 {
            self.mint_end_time.read()
        }

        fn balance_of(self: @ContractState, account: ContractAddress) -> u256 {
            assert(!account.is_zero(), 'ERC721: address zero');
            self.balances.read(account)
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read()
        }

        fn max_supply(self: @ContractState) -> u256 {
            self.max_supply.read()
        }

        fn set_base_uri(ref self: ContractState, base_uri: felt252) {
            self.base_uri.write(base_uri)
        }

        fn register_whitelist(ref self: ContractState, account: ContractAddress, amount: u256) {
            self.free_mint.write(account, amount)
        }

        fn is_approved_for_all(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self._is_approved_for_all(owner, operator)
        }
        
        fn is_free_mint_active(self: @ContractState) -> bool {
            let current_time: u64 = get_block_timestamp();
            self.mint_end_time.read() > current_time
        }

        // fn is_paid_mint_active(self: @ContractState) -> bool {
        //     let current_time: u64 = get_block_timestamp();
        //     paid_mint_start_time::read < current_time;
        // }

        fn check_free_mint(self: @ContractState, account: ContractAddress) -> u256 {
            self.free_mint.read(account)
        }

        fn token_uri(self: @ContractState, token_id: u256) -> felt252 {
            self._require_minted(token_id);
            let base_uri = self._base_uri();
            base_uri + token_id.try_into().unwrap()
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            let owner = self._owner_of(token_id);
            assert(!owner.is_zero(), 'ERC721: invalid token ID');
            owner
        }

        fn get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            self._get_approved(token_id)
        }

        fn transfer_from(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            assert(
                self._is_approved_or_owner(get_caller_address(), token_id),
                'Caller is not owner or approved'
            );
            self._transfer(from, to, token_id);
        }

        fn set_approval_for_all(
            ref self: ContractState, operator: ContractAddress, approved: bool
        ) {
            self._set_approval_for_all(get_caller_address(), operator, approved);
        }

        fn approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            let owner = self._owner_of(token_id);
            // Unlike Solidity, require is not supported, only assert can be used
            // The max length of error msg is 31 or there's an error
            assert(to != owner, 'Approval to current owner');
            assert(
                (get_caller_address() == owner)
                    || self._is_approved_for_all(owner, get_caller_address()),
                'Not token owner'
            );
            self._approve(to, token_id);
        }

        fn mint(ref self: ContractState, amount: u256) {
            assert(self.total_supply.read() < self.max_supply.read(), 'All token is minted');
            assert(get_block_timestamp() < self.mint_end_time.read(), 'Minting is ended');
            self._safe_mint(amount);
        }
    }

    #[external(v0)]
    fn safe_transfer_from(
        ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
    ) {
        assert(
            self._is_approved_or_owner(get_caller_address(), token_id),
            'caller is not owner | approved'
        );
        self._safe_transfer(from, to, token_id, ArrayTrait::<felt252>::new().span());
    }


    /// looks like overloading is not supported currently
    // fn safe_transfer_from(
    //     ref self: ContractState,
    //     from: ContractAddress,
    //     to: ContractAddress,
    //     token_id: u256,
    //     _data: Span<felt252>
    // ) {
    //     assert(self._is_approved_or_owner(get_caller_address(), token_id), 
    //         'caller is not owner | approved');
    //     self._safe_transfer(from, to, token_id, _data);
    // }

    // function _safeMint(address to, uint256 tokenId)

    #[generate_trait]
    impl StorageImpl of StorageTrait {
        fn _set_approval_for_all(
            ref self: ContractState,
            owner: ContractAddress,
            operator: ContractAddress,
            approved: bool
        ) {
            assert(owner != operator, 'ERC721: approve to caller');
            self.operator_approvals.write((owner, operator), approved);
            self.emit(Event::ApprovalForAll(ApprovalForAll { owner, operator, approved }));
        }

        fn _approve(ref self: ContractState, to: ContractAddress, token_id: u256) {
            self.token_approvals.write(token_id, to);
            self.emit(Event::Approval(Approval { owner: self._owner_of(token_id), to, token_id }));
        }

        fn _is_approved_for_all(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress
        ) -> bool {
            self.operator_approvals.read((owner, operator))
        }

        fn _owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.owners.read(token_id)
        }

        fn _exists(self: @ContractState, token_id: u256) -> bool {
            !self._owner_of(token_id).is_zero()
        }

        fn _base_uri(self: @ContractState) -> felt252 {
            ''
        }

        fn _get_approved(self: @ContractState, token_id: u256) -> ContractAddress {
            self._require_minted(token_id);
            self.token_approvals.read(token_id)
        }

        fn _require_minted(self: @ContractState, token_id: u256) {
            assert(self._exists(token_id), 'ERC721: invalid token ID');
        }

        fn _is_approved_or_owner(
            self: @ContractState, spender: ContractAddress, token_id: u256
        ) -> bool {
            let owner = self.owners.read(token_id);
            (spender == owner)
                || self._is_approved_for_all(owner, spender)
                || (self._get_approved(token_id) == spender)
        }

        fn _transfer(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256
        ) {
            assert(from == self._owner_of(token_id), 'Transfer from incorrect owner');
            assert(!to.is_zero(), 'ERC721: transfer to 0');

            self._before_token_transfer(from, to, token_id, 1.into());
            assert(from == self._owner_of(token_id), 'Transfer from incorrect owner');

            self.token_approvals.write(token_id, contract_address_const::<0>());

            self.balances.write(from, self.balances.read(from) - 1.into());
            self.balances.write(to, self.balances.read(to) + 1.into());

            self.owners.write(token_id, to);

            self.emit(Event::Transfer(Transfer { from, to, token_id }));

            self._after_token_transfer(from, to, token_id, 1.into());
        }

        fn _mint(ref self: ContractState, to: ContractAddress, token_id: u256) {
            let to = get_caller_address();
            assert(!to.is_zero(), 'ERC721: mint to 0');
            assert(!self._exists(token_id), 'ERC721: already minted');
            self._before_token_transfer(contract_address_const::<0>(), to, token_id, 1.into());
            assert(!self._exists(token_id), 'ERC721: already minted');

            self.balances.write(to, self.balances.read(to) + 1.into());
            self.owners.write(token_id, to);
            // contract_address_const::<0>() => means 0 address
            self
                .emit(
                    Event::Transfer(Transfer { from: contract_address_const::<0>(), to, token_id })
                );

            self._after_token_transfer(contract_address_const::<0>(), to, token_id, 1.into());
        }


        fn _burn(ref self: ContractState, token_id: u256) {
            let owner = self._owner_of(token_id);
            self._before_token_transfer(owner, contract_address_const::<0>(), token_id, 1.into());
            let owner = self._owner_of(token_id);
            self.token_approvals.write(token_id, contract_address_const::<0>());

            self.balances.write(owner, self.balances.read(owner) - 1.into());
            self.owners.write(token_id, contract_address_const::<0>());
            self
                .emit(
                    Event::Transfer(
                        Transfer { from: owner, to: contract_address_const::<0>(), token_id }
                    )
                );

            self._after_token_transfer(owner, contract_address_const::<0>(), token_id, 1.into());
        }

        fn _safe_mint(ref self: ContractState, amount: u256) {
            let mut current_id = self.total_supply.read();
            let to = get_caller_address();
            let mint_counter = self.free_mint.read(to);
            let mut counter = 0;
            loop {
                if counter > mint_counter {
                    break;
                }
                current_id = current_id + 1;
                self._mint(to, current_id);
                    assert(
                        self
                        ._check_on_ERC721_received(
                            contract_address_const::<0>(),
                            to,
                            current_id,
                            ArrayTrait::<felt252>::new().span()
                        ),
                    'transfer to non ERC721Receiver'
                );
                counter = counter + 1;
            };
            self.total_supply.write(current_id);
        }

        /// looks like overloading is not supported currently
        // fn _safe_mint(
        //     ref self: ContractState, 
        //     to: ContractAddress, 
        //     token_id: u256, 
        //     _data: Span<felt252>
        // ) {
        //     self._mint(to, token_id);
        //     assert(self._check_on_ERC721_received(contract_address_const::<0>(), to, token_id, _data), 
        //         'transfer to non ERC721Receiver');
        // }

        fn _safe_transfer(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            _data: Span<felt252>
        ) {
            self._transfer(from, to, token_id);
            assert(
                self._check_on_ERC721_received(from, to, token_id, _data),
                'transfer to non ERC721Receiver'
            );
        }

        fn _check_on_ERC721_received(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            _data: Span<felt252>
        ) -> bool {
            ERC721Receiver { contract_address: to }
                .on_erc721_received(get_caller_address(), from, token_id, _data);
            // todo
            true
        }

        fn _before_token_transfer(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            first_token_id: u256,
            batch_size: u256
        ) {}

        fn _after_token_transfer(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            first_token_id: u256,
            batch_size: u256
        ) {}
    }
}