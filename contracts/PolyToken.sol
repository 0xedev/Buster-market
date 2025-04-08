// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.6;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PolyToken is ERC20 {
    address public owner;

    constructor() ERC20("Poly Token", "POLY") {
        owner = msg.sender;
        _mint(msg.sender, 100000 * 10**18);
    }

}
