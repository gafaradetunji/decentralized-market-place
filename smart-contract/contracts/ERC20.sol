// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ERC20Mock is ERC20 {
    uint8 private _customDecimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 _decimals,
        address initialAccount,
        uint256 initialBalance
    ) ERC20(name, symbol) {
        _customDecimals = _decimals;
        _mint(initialAccount, initialBalance);
    }

    function decimals() public view virtual override returns (uint8) {
        return _customDecimals;
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}
