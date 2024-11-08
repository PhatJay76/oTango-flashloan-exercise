// SPDX-License-Identifier: MIT
pragma solidity 0.8.21;

import "@balancer-labs/v2-interfaces/contracts/vault/IVault.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@prb/math/src/SD59x18.sol";
import "./interfaces/IERC7399.sol";

interface IOTANGO {
    function exercise(SD59x18 amount) external;
}

contract FlashLoan is Ownable {
    // Balancer vault
    address private constant VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    // Dolomite flash provider wrapper
    address private constant FLASH_PROVIDER = 0x54F1ce5E6bdf027C9a6016C9F52fC5A445b77ed6;
    // USDC.e
    address private constant USDC = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    // wstETH
    address private constant WSTETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    // Tango
    address private constant TANGO = 0xC760F9782F8ceA5B06D862574464729537159966;
    // oTANGO
    address private constant OTANGO = 0x0000000000000000000000000000000000000000;
    // wstETH-USDC Balancer pool
    bytes32 private constant WSTETH_USDC_POOL = 0x178e029173417b1f9c8bc16dcec6f697bc323746000200000000000000000158;
    // wstETH-TANGO Balancer pool
    bytes32 private constant WSTETH_TANGO_POOL = 0x1ed1e6fa76e3dd9ea68d1fd8c4b8626ea5648dfa0002000000000000000005cb;

    constructor() Ownable(msg.sender) {}
    
    /**
     * @notice Executes a swap using Balancer Batch Swap
     * @param amountIn structure of swap parameters
     */
    function _swapToken(uint256 amountIn) internal {
        IERC20(TANGO).approve(VAULT, amountIn);

        IVault.BatchSwapStep[] memory steps = new IVault.BatchSwapStep[](2);

        // TANGO -> wstETH
        steps[0] = IVault.BatchSwapStep({
            poolId: WSTETH_TANGO_POOL,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: amountIn,
            userData: ""
        });
        
        // wstETH -> USDC
        steps[1] = IVault.BatchSwapStep({
            poolId: WSTETH_USDC_POOL,
            assetInIndex: 1,
            assetOutIndex: 2,
            amount: 0, // Amount filled by previous step
            userData: ""
        });

        // Setup tokens array
        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(TANGO);
        assets[1] = IAsset(WSTETH);
        assets[2] = IAsset(USDC);

        // Setup limits
        int256[] memory limits = new int256[](3);
        limits[0] = int256(amountIn); 
        limits[1] = type(int256).max;
        limits[2] = type(int256).min;

        // Setup fund management
        IVault.FundManagement memory funds = IVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        // Execute swap
        IVault(VAULT).batchSwap(
            IVault.SwapKind.GIVEN_IN,
            steps,
            assets,
            funds,
            limits,
            block.timestamp
        );
    }

     /**
     * @notice exercises the oTANGO Perpetual Option contract
     * @param amount Amount of input token to swap
     */
    function _exerciseOption(
        uint256 amount,
        SD59x18 shares
    ) internal {
        IERC20(USDC).approve(OTANGO, amount);
        IOTANGO(OTANGO).exercise(shares);
    }

    /**
     * @notice Initiates a flash loan from Dolomite, 
     *         Swaps USDC into TANGO, 
     *         exercise oTANGO option, 
     *         repays flash loan with recieved USDC
     * @param amount amount to flash loan - remembering that USDC uses 6 decimals
     * @param shares amount of shares of oTango to excerise
     */
    function exerciseFlash(
        uint256 amount,
        SD59x18 shares
    ) external onlyOwner {
        bytes memory userData = abi.encode(shares);
        IERC7399(FLASH_PROVIDER).flash(
            address(this),
            USDC,
            amount,
            userData,
            this.receiveFlashLoan
        );
    }

    /**
     * @notice Callback function to handle flash loan
     * @dev This function must approve the repay the flash loan
     * @param initiator The address receiving the flash loan
     * @param paymentReceiver Array of borrowed amounts
     * @param amount borrowed amount
     * @param fee amount of fee to pay
     * @param data encoded user data containing number of shares to execute
     */
    function receiveFlashLoan(
        address initiator,
        address paymentReceiver,
        address,
        uint256 amount,
        uint256 fee,
        bytes memory data
    ) external returns (bytes memory) {
        require(msg.sender == FLASH_PROVIDER, "not the flash provider");
        require(initiator == address(this), "Unauthorized contract");
        (SD59x18 shares) = abi.decode(data, (SD59x18));
        _exerciseOption(amount, shares);
        _swapToken(IERC20(TANGO).balanceOf(address(this)));
        uint256 repayAmount = amount + fee;
        IERC20(USDC).approve(paymentReceiver, repayAmount);
        IERC20(USDC).transfer(owner(), IERC20(USDC).balanceOf(address(this)) - repayAmount);
        IERC20(TANGO).transfer(owner(), IERC20(TANGO).balanceOf(address(this)));
        return abi.encode(true);
    }

    /**
     * @notice Allows owner to withdraw tokens sent to contract (just in case)
     * @param token Address of token to recover
     */
    function withdrawToken(address token) external onlyOwner  {
        IERC20(token).transfer(owner(), IERC20(token).balanceOf(address(this)));
    }
}
