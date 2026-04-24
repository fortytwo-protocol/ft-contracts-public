// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.29;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {LibClone} from "@solady/utils/LibClone.sol";
import {IERC6909, IERC6909Metadata} from "@openzeppelin/contracts/interfaces/IERC6909.sol";

library SafeERC6909 {
    error SafeTransferFailed();
    error SafeTransferFromFailed();
    error InvalidERC6909Token();

    function safeTransfer(address token, address to, uint256 id, uint256 amount) internal {
        require(token.code.length > 0, InvalidERC6909Token());
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC6909.transfer, (to, id, amount)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), SafeTransferFailed());
    }

    function safeTransferFrom(address token, address from, address to, uint256 id, uint256 amount) internal {
        require(token.code.length > 0, InvalidERC6909Token());
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC6909.transferFrom, (from, to, id, amount)));
        require(success && (data.length == 0 || abi.decode(data, (bool))), SafeTransferFromFailed());
    }
}

contract Wrapped6909 is ERC20Upgradeable, ReentrancyGuardTransient {
    string private constant GENERIC_NAME = "Wrapped ERC-6909";
    string private constant GENERIC_SYMBOL = "WERC6909";

    address public factory;
    IERC6909Metadata public token;
    uint256 public tokenId;

    error OnlyFactory();

    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        require(msg.sender == factory, OnlyFactory());
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @dev No ERC20 init — name/symbol/decimals depend on underlying ERC6909 which can be mutable
    function initialize(address factory_, address token_, uint256 tokenId_) external initializer {
        factory = factory_;
        token = IERC6909Metadata(token_);
        tokenId = tokenId_;
    }

    /**
     * @dev Wraps ERC6909 to ERC20. Receive underlying ERC6909 and send 1:1 of ERC20 to receiver.
     */
    function deposit(uint256 amount, address receiver) external nonReentrant {
        SafeERC6909.safeTransferFrom(address(token), msg.sender, address(this), tokenId, amount);
        _mint(receiver, amount);
    }

    /**
     * @dev Unwrap ERC20 to ERC6909. Burn ERC20 from owner and send 1:1 ERC6909 to receiver.
     * Approvals not required if msg.sender == owner.
     */
    function withdraw(uint256 amount, address receiver, address owner) external nonReentrant {
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, amount);
        }

        _burn(owner, amount);
        SafeERC6909.safeTransfer(address(token), receiver, tokenId, amount);
    }

    /**
     * @dev factory only function, to support factory as entrypoint
     */
    function withdrawFrom(uint256 amount, address receiver, address from) external nonReentrant onlyFactory {
        _burn(from, amount);
        SafeERC6909.safeTransfer(address(token), receiver, tokenId, amount);
    }

    /**
     * @dev factory only function, to support factory as entrypoint
     */
    function mint(address receiver, uint256 amount) external nonReentrant onlyFactory {
        _mint(receiver, amount);
    }

    function name() public view override returns (string memory) {
        try token.name(tokenId) returns (string memory name6909) {
            return name6909;
        } catch {
            return GENERIC_NAME;
        }
    }

    function symbol() public view override returns (string memory) {
        try token.symbol(tokenId) returns (string memory symbol6909) {
            return symbol6909;
        } catch {
            return GENERIC_SYMBOL;
        }
    }

    /**
     * @dev Unlike name and symbol, we follow the underlying ERC6909,
     * if it does not implement decimals, this will revert.
     * This avoids incorrect calculations that depend on decimals.
     */
    function decimals() public view override returns (uint8) {
        return token.decimals(tokenId);
    }
}

/**
 * @notice ERC6909-to-ERC20 wrapper factory using ERC1167 minimal proxies (solady's LibClone).
 * Fork of gnosis's ERC1155-to-ERC20 factory adapted for ERC6909s.
 * Reference: https://github.com/gnosis/1155-to-20/blob/master/contracts/Wrapped1155Factory.sol
 */
contract Wrapped6909Factory {
    address private immutable IMPLEMENTATION;

    event Wrapped6909Creation(address indexed token, uint256 indexed tokenId, address indexed clone);

    error WrappedERC6909AlreadyDeployed();

    constructor() {
        IMPLEMENTATION = address(new Wrapped6909());
    }

    /**
     * @dev Wraps ERC6909 to ERC20. Requires ERC6909 approval
     * Will ensure deterministic ERC6909 contract deployment if it is not deployed.
     */
    function wrap(address token, uint256 id, uint256 amount, address receiver) external returns (address clone) {
        clone = _requireWrapped6909(token, id);
        SafeERC6909.safeTransferFrom(token, msg.sender, clone, id, amount);
        Wrapped6909(clone).mint(receiver, amount);
    }

    /**
     * @dev Wraps ERC6909 to ERC20. No ERC20 approval required
     */
    function unwrap(address token, uint256 id, uint256 amount, address receiver) external {
        address clone = _getWrapped6909(token, id);
        Wrapped6909(clone).withdrawFrom(amount, receiver, msg.sender);
    }

    /**
     * @dev Returns deterministic WrappedERC6909 contract address.
     */
    function getWrapped6909(address token, uint256 id) external view returns (address) {
        return _getWrapped6909(token, id);
    }

    /**
     * @dev Deploys WrappedERC6909 contract. Reverts if contract is already deployed.
     */
    function deploy(address token, uint256 id) external returns (address) {
        address clone = _getWrapped6909(token, id);
        require(clone.code.length == 0, WrappedERC6909AlreadyDeployed());

        return _requireWrapped6909(token, id);
    }

    function implementation() external view returns (address) {
        return IMPLEMENTATION;
    }

    function _requireWrapped6909(address token, uint256 id) internal returns (address clone) {
        bytes32 salt = _getSalt(token, id);
        clone = LibClone.predictDeterministicAddress(IMPLEMENTATION, salt, address(this));
        if (clone.code.length == 0) {
            clone = LibClone.cloneDeterministic(IMPLEMENTATION, salt);
            Wrapped6909(clone).initialize(address(this), address(token), id);
            emit Wrapped6909Creation(token, id, clone);
        }
    }

    function _getWrapped6909(address token, uint256 id) internal view returns (address) {
        return LibClone.predictDeterministicAddress(IMPLEMENTATION, _getSalt(token, id), address(this));
    }

    function _getSalt(address token, uint256 id) internal pure returns (bytes32) {
        // forge-lint: disable-next-line(asm-keccak256)
        return keccak256(abi.encode(token, id));
    }
}
