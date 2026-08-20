// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal mintable/burnable ERC-20 for tests, used both as the pool's
///         underlying currency and as the two tranche tokens.
/// @dev    Deliberately not an OpenZeppelin ERC20: the lender needs `mint` and `burn`
///         callable by the tranche, and a test double makes the required surface
///         explicit. `src/lender/interfaces.sol :: ERC20Like` is that surface. Any
///         token satisfying it works; this is the smallest one that does.
contract SimpleToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_) {
        name = name_;
        symbol = symbol_;
    }

    function mint(address usr, uint256 amount) public {
        balanceOf[usr] += amount;
        totalSupply += amount;
        emit Transfer(address(0), usr, amount);
    }

    function burn(address usr, uint256 amount) public {
        balanceOf[usr] -= amount;
        totalSupply -= amount;
        emit Transfer(usr, address(0), amount);
    }

    function approve(address usr, uint256 amount) public {
        allowance[msg.sender][usr] = amount;
        emit Approval(msg.sender, usr, amount);
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        if (from != msg.sender && allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
