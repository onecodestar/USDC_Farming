//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

interface IToken {
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    function mint(address to, uint256 value) external returns (bool);

    function transfer(address to, uint256 value) external returns (bool);

    function balanceOf(address who) external view returns (uint256);

    function allowance(address owner, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);
}

contract Ownable {
    address public owner;

    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    /**
     * @dev The Ownable constructor sets the original `owner` of the contract to the sender
     * account.
     */
    constructor() public {
        owner = msg.sender;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    /**
     * @dev Allows the current owner to transfer control of the contract to a newOwner.
     * @param newOwner The address to transfer ownership to.
     */
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0));
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

library SafeMath {
    /**
     * @dev Multiplies two numbers, throws on overflow.
     */
    function mul(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0) {
            return 0;
        }
        c = a * b;
        assert(c / a == b);
        return c;
    }

    /**
     * @dev Integer division of two numbers, truncating the quotient.
     */
    function div(uint256 a, uint256 b) internal pure returns (uint256) {
        // assert(b > 0); // Solidity automatically throws when dividing by 0
        // uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold
        return a / b;
    }

    /**
     * @dev Subtracts two numbers, throws on overflow (i.e. if subtrahend is greater than minuend).
     */
    function sub(uint256 a, uint256 b) internal pure returns (uint256) {
        assert(b <= a);
        return a - b;
    }

    /* @dev Subtracts two numbers, else returns zero */
    function safeSub(uint256 a, uint256 b) internal pure returns (uint256) {
        if (b > a) {
            return 0;
        } else {
            return a - b;
        }
    }

    /**
     * @dev Adds two numbers, throws on overflow.
     */
    function add(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        assert(c >= a);
        return c;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract Farming is Ownable {
    using SafeMath for uint256;

    struct NodeType {
        string name;
        uint256 deposit_amount;
        uint256 payout_percent;
    }
    mapping(uint256 => NodeType) public node_types;

    struct UserNode {
        address upline;
        uint256 direct_bonus;
        //Deposit Accounting
        uint256 deposits;
        uint256 deposit_time;
        //Payout and Roll Accounting
        uint256 payouts;
    }

    mapping(address => mapping(uint256 => UserNode)) public user_nodes;

    address POLYGON_USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;

    IToken private iToken;

    address public treasury_address;
    address public admin_address;
    uint256 public treasury_allocation = 35; //35% of deposit will go to treasury
    uint256 public claim_fee = 10;

    uint256 public total_users = 1; //set initial user - owner
    uint256 public total_deposited;
    uint256 public total_withdraw;

    constructor() Ownable() {
        iToken = IToken(POLYGON_USDC); // Polygon - USDC contract
        node_types[0] = NodeType("Starter", 100 * 1e18, 10);
        node_types[1] = NodeType("Pro", 500 * 1e18, 15);
        node_types[2] = NodeType("Whale", 1000 * 1e18, 20);
    }

    function deposit(uint256 _node_type_index, address _upline) public {
        require(
            _node_type_index == 0 ||
                _node_type_index == 1 ||
                _node_type_index == 2,
            "Node Type Index should be 0 or 1 or 2"
        );
        address _addr = msg.sender;
        uint256 _amount = node_types[_node_type_index].deposit_amount;

        _setUpline(_addr, _node_type_index, _upline);

        uint256 amount_to_treasury = _amount.mul(treasury_allocation).div(100);
        uint256 amount_to_faucet = _amount.sub(amount_to_treasury);
        //Transfer Token to the contract
        // require(
        //     iToken.transferFrom(_addr, address(this), amount_to_faucet),
        //     "token transfer failed"
        // );
        // require(
        //     iToken.transferFrom(
        //         _addr,
        //         address(treasury_address),
        //         amount_to_treasury
        //     ),
        //     "token transfer failed"
        // );

        _deposit(_addr, _node_type_index, _amount);
    }

    function _deposit(
        address _addr,
        uint256 _node_type_index,
        uint256 _amount
    ) internal {
        user_nodes[_addr][_node_type_index].deposits += _amount;
        user_nodes[_addr][_node_type_index].deposit_time = block.timestamp;

        total_deposited += _amount;
        //5% direct commission; only if net positive
        address _up = user_nodes[_addr][_node_type_index].upline;
        if (_up != address(0)) {
            uint256 _bonus = _amount / 20; //5% for referral

            user_nodes[_up][_node_type_index].direct_bonus += _bonus;
            user_nodes[_up][_node_type_index].deposits += _bonus;
        }
    }

    function _setUpline(
        address _addr,
        uint256 _node_type_index,
        address _upline
    ) internal {
        if (_upline != _addr && _upline != address(0)) {
            user_nodes[_addr][_node_type_index].upline = _upline;
            total_users++;
        }
    }

    function claim_all() public { // check avaialbe nodes
        address _addr = msg.sender;
        claim(_addr, 0);
        claim(_addr, 1);
        claim(_addr, 2);
    }

    function claim(address _addr, uint256 _node_type_index) internal {
        uint256 to_payout = _claim(_addr, _node_type_index);

        uint256 this_balance = iToken.balanceOf(address(this));
        if (this_balance < to_payout) {
            uint256 difference_amount = to_payout.sub(this_balance);
            require(
                iToken.transferFrom(
                    treasury_address,
                    address(this),
                    difference_amount
                ),
                "token transfer failed"
            );
        }
        //Apply fee if user claims before 1 month
        uint256 fee_percent = 0;
        if (
            block.timestamp <
            user_nodes[_addr][_node_type_index].deposit_time + 30 days
        ) fee_percent = claim_fee;

        uint256 fee = to_payout.mul(claim_fee).div(100);
        uint256 realizedPayout = to_payout.sub(fee);
        require(iToken.transfer(_addr, realizedPayout));
        require(iToken.transfer(admin_address, fee));
    }

    function _claim(address _addr, uint256 _node_type_index)
        internal
        returns (uint256)
    {
        uint256 _to_payout = payoutOf(_addr, _node_type_index);
        // Deposit payout
        if (_to_payout > 0) {
            user_nodes[_addr][_node_type_index].payouts += _to_payout;
        }

        require(_to_payout > 0, "Zero payout");

        //Update the payouts
        total_withdraw += _to_payout;

        //Update time!
        user_nodes[_addr][_node_type_index].deposit_time = block.timestamp;

        return _to_payout;
    }

    function payoutOf(address _addr, uint256 _node_type_index)
        public
        view
        returns (uint256 payout)
    {
        uint256 share = user_nodes[_addr][_node_type_index]
            .deposits
            .mul(node_types[_node_type_index].payout_percent * 1e18)
            .div(100e18)
            .div(24 hours * 30);
        payout =
            share *
            block.timestamp.safeSub(
                user_nodes[_addr][_node_type_index].deposit_time
            );
    }

    //Admin side function
    function setStablecoinAddress(address _tokenadd) public onlyOwner {
        iToken = IToken(_tokenadd);
    }

    function setTreasuryAddress(address _treasuryadd) public onlyOwner {
        treasury_address = _treasuryadd;
    }

    function setAdminAddress(address addr) public onlyOwner {
        admin_address = addr;
    }

    function setCalimFee(uint256 fee) public onlyOwner {
        claim_fee = fee;
    }

    function setTreasuryAllocation(uint256 _treasuryallocation)
        public
        onlyOwner
    {
        require(_treasuryallocation < 100, "should be less than 100.");
        treasury_allocation = _treasuryallocation;
    }

    function setNodeTypes(
        uint256 _node_type_index,
        string memory name,
        uint256 deposit_amount,
        uint256 payout_percent
    ) public onlyOwner {
        node_types[_node_type_index] = NodeType(
            name,
            deposit_amount,
            payout_percent
        );
    }
}
