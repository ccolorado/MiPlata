// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;


// Importaciones de OpenZeppelin
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// Importaciones de Chainlink
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

// Importaciones de Uniswap V3
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

// Importaciones de Aave V3
import "@aave/core-v3/contracts/interfaces/IPool.sol";

// Librerías de Uniswap V3
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

contract InvestmentStrategy is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Declaración de variables y estructuras
    IERC20 public usdc;
    IERC20 public weth;
    ISwapRouter public uniswapRouter;
    IPool public aavePool;
    AggregatorV3Interface public ethUsdPriceFeed;
    IUniswapV3Pool public uniswapPool;
    INonfungiblePositionManager public positionManager;

    uint256 public constant FEE_PERCENTAGE = 25; // 0.25%
    uint256 public constant MINIMUM_INVESTMENT = 10 * 1e6; // 10 USDC
    uint256 public constant MAX_INVESTMENT = 1_000_000 * 1e6; // 1 millón USDC
    uint256 public constant AMPLITUDE_RISKY = 5;
    uint256 public constant AMPLITUDE_MODERATE = 10;
    uint256 public constant AMPLITUDE_CONSERVATIVE = 15;
    uint256 public constant REBALANCE_THRESHOLD = 500; // Representa 5% en base 10000
    uint256 public constant COMPOUND_THRESHOLD = 100 * 1e6; // 100 USDC en fees

    uint256 public totalInvestment;
    uint256 public lastRebalance;
    uint256 public lastCompound;
    uint256 public accumulatedFees;
    address public feeCollector;

    enum InvestmentType { Risky, Moderate, Conservative }

    struct UserInvestment {
        uint256 investmentId;
        InvestmentType investmentType;
        uint256 usdcDeposited;
        uint256 wethBorrowed;
        uint256 lastAutoCompound;
        uint256 amplitude;
        uint256 tokenId; // ID del NFT de la posición en Uniswap V3
        uint256 lastEthPrice; // Último precio de ETH/USD registrado
        uint256 timestamp; // Marca de tiempo de la inversión
    }

    mapping(address => UserInvestment[]) public investments;
    mapping(address => uint256) private userInvestmentCounters;
    uint256 public userCount;
    mapping(uint256 => address) public userAddresses;
    uint256 public lastProcessedUserIndex;

    event InvestmentMade(address indexed user, uint256 investmentId, uint256 amount, InvestmentType investmentType, uint256 amplitude);
    event Withdrawn(address indexed user, uint256 investmentId, uint256 amount);
    event Rebalanced(uint256 timestamp);
    event Compounded(uint256 timestamp, uint256 amount);
    event RebalancedInvestment(address indexed user, uint256 investmentId, uint256 timestamp);
    event EmergencyWithdrawal(address indexed user, uint256 usdcAmount, uint256 wethAmount, uint256 timestamp);

    constructor() Ownable() {
        usdc = IERC20(0x036CbD53842c5426634e7929541eC2318f3dCF7e); // USDC en Base Sepolia
        weth = IERC20(0x4200000000000000000000000000000000000006); // WETH en Base Sepolia
        uniswapRouter = ISwapRouter(0x94cC0AaC535CCDB3C01d6787D6413C739ae12bc4); // Uniswap V3 Router
        aavePool = IPool(0x4ff1A755C4F24F30C2eCBd64A1F1a91857E8A2e1); // Aave Pool
        ethUsdPriceFeed = AggregatorV3Interface(0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1); // Chainlink ETH/USD Feed
        uniswapPool = IUniswapV3Pool(0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24); // Uniswap V3 Pool
        positionManager = INonfungiblePositionManager(0x27F971cb582BF9E50F397e4d29a5C7A34f11faA2); // NFT Position Manager
        feeCollector = 0x7B3B786C36720F0d367F62dDb4e4B98e6f54DffD; // Gnosis Safe Wallet
    }

    function invest(uint256 amount, InvestmentType investmentType)
        external nonReentrant whenNotPaused 
    {
        require(amount >= MINIMUM_INVESTMENT, "Monto mínimo no alcanzado");
        require(amount <= MAX_INVESTMENT, "Monto máximo excedido");
        require(totalInvestment + amount <= MAX_INVESTMENT, "Límite total excedido");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        uint256 fee = (amount * FEE_PERCENTAGE) / 10000; // 0.25% de fee
        uint256 netAmount = amount - fee;
        usdc.safeTransfer(feeCollector, fee);

        // Asignar el 100% del netAmount
        uint256 usdcCollateral = (netAmount * 6275) / 10000; // 62.75%
        uint256 borrowAmount = (netAmount * 3725) / 10000;   // 37.25%

        depositToAave(usdcCollateral);
        uint256 wethBorrowed = borrowFromAave(borrowAmount);

        uint256 amplitude = getAmplitude(investmentType);
        uint256 tokenId = createUniswapPosition(usdcCollateral, wethBorrowed, amplitude);

        uint256 currentEthPrice = getETHUSDPrice();

        uint256 investmentId = userInvestmentCounters[msg.sender];
        userInvestmentCounters[msg.sender] += 1;

        UserInvestment memory newInvestment = UserInvestment({
            investmentId: investmentId,
            investmentType: investmentType,
            usdcDeposited: usdcCollateral,
            wethBorrowed: wethBorrowed,
            lastAutoCompound: block.timestamp,
            amplitude: amplitude,
            tokenId: tokenId,
            lastEthPrice: currentEthPrice,
            timestamp: block.timestamp
        });

        investments[msg.sender].push(newInvestment);

        // Agregar usuario si es nuevo
        if (investments[msg.sender].length == 1) {
            userAddresses[userCount] = msg.sender;
            userCount++;
        }

        totalInvestment += netAmount;
        emit InvestmentMade(msg.sender, newInvestment.investmentId, netAmount, investmentType, amplitude);
    }

    function withdraw(uint256 investmentId) external nonReentrant whenNotPaused {
        UserInvestment[] storage userInvestments = investments[msg.sender];
        uint256 index = getInvestmentIndex(msg.sender, investmentId);
        UserInvestment storage investment = userInvestments[index];
        require(investment.usdcDeposited > 0, "No hay inversión activa");

        closeUniswapPosition(investment.tokenId);
        repayAaveLoan(investment.wethBorrowed);
        withdrawFromAave(investment.usdcDeposited);

        uint256 totalAmount = investment.usdcDeposited + swapWETHtoUSDC(weth.balanceOf(address(this)));

        totalInvestment -= totalAmount;

        // Eliminar la inversión del array
        userInvestments[index] = userInvestments[userInvestments.length - 1];
        userInvestments.pop();

        // Eliminar usuario de userAddresses si no tiene más inversiones
        if (userInvestments.length == 0) {
            for (uint256 i = 0; i < userCount; i++) {
                if (userAddresses[i] == msg.sender) {
                    userAddresses[i] = userAddresses[userCount - 1];
                    delete userAddresses[userCount - 1];
                    userCount--;
                    break;
                }
            }
        }

        usdc.safeTransfer(msg.sender, totalAmount);
        emit Withdrawn(msg.sender, investmentId, totalAmount);
    }

    function depositToAave(uint256 amount) internal {
        ensureApproval(usdc, address(aavePool), amount);
        aavePool.supply(address(usdc), amount, address(this), 0);
    }

    function borrowFromAave(uint256 amount) internal returns (uint256) {
        aavePool.borrow(address(weth), amount, 2, 0, address(this));
        return amount;
    }

    function repayAaveLoan(uint256 amount) internal {
        ensureApproval(weth, address(aavePool), amount);
        aavePool.repay(address(weth), amount, 2, address(this));
    }

    function withdrawFromAave(uint256 amount) internal {
        aavePool.withdraw(address(usdc), amount, address(this));
    }

    function createUniswapPosition(
        uint256 usdcAmount, 
        uint256 wethAmount, 
        uint256 amplitude
    ) internal returns (uint256 tokenId) {
        ensureApproval(usdc, address(positionManager), usdcAmount);
        ensureApproval(weth, address(positionManager), wethAmount);

        int24 tickSpacing = uniswapPool.tickSpacing();
        (, int24 currentTick, , , , , ) = uniswapPool.slot0();

        int24 tickLower = currentTick - (int24(amplitude) * tickSpacing);
        int24 tickUpper = currentTick + (int24(amplitude) * tickSpacing);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(usdc),
            token1: address(weth),
            fee: 3000,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: usdcAmount,
            amount1Desired: wethAmount,
            amount0Min: (usdcAmount * 99) / 100, // 1% slippage tolerance
            amount1Min: (wethAmount * 99) / 100, // 1% slippage tolerance
            recipient: address(this),
            deadline: block.timestamp + 900 // 15 minutes
        });

        (tokenId, , , ) = positionManager.mint(params);
        require(tokenId != 0, "Error al crear posición en Uniswap");
    }

    function closeUniswapPosition(uint256 tokenId) internal {
        // Verificar que el tokenId pertenece al contrato
        ( , , address tokenOwner, , , , , , , , , ) = positionManager.positions(tokenId);
        require(tokenOwner == address(this), "Token ID no pertenece al contrato");

        uint128 liquidity = getLiquidity(tokenId);

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 900 // 15 minutes
        });

        positionManager.decreaseLiquidity(params);

        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        positionManager.collect(collectParams);
        positionManager.burn(tokenId);
    }

    function getLiquidity(uint256 tokenId) internal view returns (uint128) {
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);
        return liquidity;
    }

    function swapWETHtoUSDC(uint256 wethAmount) internal returns (uint256) {
        ensureApproval(weth, address(uniswapRouter), wethAmount);

        // Realizar el swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(usdc),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 900, // 15 minutes
            amountIn: wethAmount,
            amountOutMinimum: 0, // Aceptamos cualquier cantidad
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        return amountOut;
    }

    function swapUSDCtoWETH(uint256 usdcAmount) internal returns (uint256) {
        ensureApproval(usdc, address(uniswapRouter), usdcAmount);

        // Realizar el swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(weth),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 900, // 15 minutes
            amountIn: usdcAmount,
            amountOutMinimum: 0, // Aceptamos cualquier cantidad
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapRouter.exactInputSingle(params);
        return amountOut;
    }

    function getAmplitude(InvestmentType investmentType) internal pure returns (uint256) {
        if (investmentType == InvestmentType.Risky) return AMPLITUDE_RISKY;
        if (investmentType == InvestmentType.Moderate) return AMPLITUDE_MODERATE;
        return AMPLITUDE_CONSERVATIVE;
    }

    function getInvestmentIndex(address user, uint256 investmentId) internal view returns (uint256) {
        UserInvestment[] storage userInvestments = investments[user];
        for (uint256 i = 0; i < userInvestments.length; i++) {
            if (userInvestments[i].investmentId == investmentId) {
                return i;
            }
        }
        revert("Inversión no encontrada");
    }

    function checkIfRebalanceNeeded() internal view returns (bool) {
        uint256 currentEthPrice = getETHUSDPrice();
        for (uint256 i = 0; i < userCount; i++) {
            address user = userAddresses[i];
            UserInvestment[] storage userInvestments = investments[user];
            for (uint256 j = 0; j < userInvestments.length; j++) {
                UserInvestment storage investment = userInvestments[j];
                if (needsRebalance(investment, currentEthPrice)) {
                    return true;
                }
            }
        }
        return false;
    }

    function needsRebalance(UserInvestment storage investment, uint256 currentEthPrice) internal view returns (bool) {
        uint256 lastPrice = investment.lastEthPrice;
        uint256 priceChange = (currentEthPrice > lastPrice)
            ? ((currentEthPrice - lastPrice) * 10000) / lastPrice
            : ((lastPrice - currentEthPrice) * 10000) / lastPrice;

        // Umbral de cambio de precio definido por REBALANCE_THRESHOLD
        return priceChange >= REBALANCE_THRESHOLD;
    }

    function rebalancePositions(uint256 maxUsers) internal whenNotPaused {
        require(block.timestamp >= lastRebalance + 1 days, "Rebalanceo demasiado frecuente");

        uint256 usersProcessed = 0;
        uint256 currentEthPrice = getETHUSDPrice();

        while (usersProcessed < maxUsers && lastProcessedUserIndex < userCount) {
            address user = userAddresses[lastProcessedUserIndex];
            UserInvestment[] storage userInvestments = investments[user];
            for (uint256 j = 0; j < userInvestments.length; j++) {
                UserInvestment storage investment = userInvestments[j];
                if (needsRebalance(investment, currentEthPrice)) {
                    // Cerrar la posición existente
                    closeUniswapPosition(investment.tokenId);
                    repayAaveLoan(investment.wethBorrowed);
                    withdrawFromAave(investment.usdcDeposited);

                    // Recalcular los montos
                    uint256 totalAmount = investment.usdcDeposited + swapWETHtoUSDC(weth.balanceOf(address(this)));

                    uint256 fee = (totalAmount * FEE_PERCENTAGE) / 10000; // 0.25% de fee
                    uint256 netAmount = totalAmount - fee;
                    usdc.safeTransfer(feeCollector, fee);

                    // Asignar el 100% del netAmount
                    uint256 usdcCollateral = (netAmount * 6275) / 10000; // 62.75%
                    uint256 borrowAmount = (netAmount * 3725) / 10000;   // 37.25%

                    // Reabrir la posición
                    depositToAave(usdcCollateral);
                    uint256 wethBorrowed = borrowFromAave(borrowAmount);

                    uint256 tokenId = createUniswapPosition(usdcCollateral, wethBorrowed, investment.amplitude);

                    // Actualizar la inversión
                    investment.usdcDeposited = usdcCollateral;
                    investment.wethBorrowed = wethBorrowed;
                    investment.tokenId = tokenId;
                    investment.lastEthPrice = currentEthPrice;
                    investment.lastAutoCompound = block.timestamp;

                    emit RebalancedInvestment(user, investment.investmentId, block.timestamp);
                }
            }
            lastProcessedUserIndex++;
            usersProcessed++;
        }

        if (lastProcessedUserIndex >= userCount) {
            lastProcessedUserIndex = 0; // Reiniciar el índice para la próxima vez
        }

        lastRebalance = block.timestamp;
        emit Rebalanced(block.timestamp);
    }

    function compoundPositions(uint256 maxUsers) internal whenNotPaused {
        require(block.timestamp >= lastCompound + 1 days, "Compound demasiado frecuente");

        uint256 fees = accumulatedFees;
        if (fees >= COMPOUND_THRESHOLD) {
            reinvestInLP(fees);
            accumulatedFees = 0;
            lastCompound = block.timestamp;

            emit Compounded(block.timestamp, fees);
        }
    }

    function reinvestInLP(uint256 amount) internal {
        uint256 halfAmount = amount / 2;
        uint256 wethAmount = swapUSDCtoWETH(halfAmount);
        uint256 usdcAmount = amount - halfAmount;

        // Crear una nueva posición en Uniswap con los fondos reinvertidos
        ensureApproval(usdc, address(positionManager), usdcAmount);
        ensureApproval(weth, address(positionManager), wethAmount);

        int24 tickSpacing = uniswapPool.tickSpacing();
        (, int24 currentTick, , , , , ) = uniswapPool.slot0();

        int24 tickLower = currentTick - (int24(AMPLITUDE_MODERATE) * tickSpacing);
        int24 tickUpper = currentTick + (int24(AMPLITUDE_MODERATE) * tickSpacing);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(usdc),
            token1: address(weth),
            fee: 3000,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: usdcAmount,
            amount1Desired: wethAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp + 900 // 15 minutes
        });

        positionManager.mint(params);
    }

    function getETHUSDPrice() internal view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = ethUsdPriceFeed.latestRoundData();
        require(price > 0, "Precio ETH/USD inválido");
        require(block.timestamp - updatedAt < 1 hours, "Precio ETH/USD desactualizado");
        return uint256(price); // 8 decimales
    }

    function emergencyWithdraw() external onlyOwner {
        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 wethBalance = weth.balanceOf(address(this));

        if (usdcBalance > 0) usdc.safeTransfer(owner(), usdcBalance);
        if (wethBalance > 0) weth.safeTransfer(owner(), wethBalance);

        emit EmergencyWithdrawal(owner(), usdcBalance, wethBalance, block.timestamp);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function ensureApproval(IERC20 token, address spender, uint256 amount) internal {
        uint256 currentAllowance = token.allowance(address(this), spender);
        if (currentAllowance < amount) {
            token.safeApprove(spender, type(uint256).max);
        }
    }

    // Función para obtener el valor actual de una inversión en USDC
    function getInvestmentValue(uint256 investmentId) external view returns (uint256) {
        UserInvestment storage investment = investments[msg.sender][getInvestmentIndex(msg.sender, investmentId)];

        // Calcular el valor de la posición LP
        uint256 lpValue = getCurrentLpValue(investment.tokenId);

        // Obtener el valor del colateral y el valor del préstamo
        uint256 collateralValue = investment.usdcDeposited;
        uint256 loanValue = investment.wethBorrowed;

        // Valor total de la inversión
        uint256 totalValue = lpValue + collateralValue - loanValue;

        return totalValue;
    }

    function getCurrentLpValue(uint256 tokenId) internal view returns (uint256) {
        // Obtener la cantidad de tokens en la posición
        (uint256 amountUSDC, uint256 amountWETH) = getAmountsFromPosition(tokenId);

        // Obtener el precio actual de ETH en USDC
        uint256 ethPrice = getETHUSDPrice(); // 8 decimales

        // Calcular el valor en USDC de WETH
        uint256 wethValueInUSDC = (amountWETH * ethPrice) / 1e8;

        // Sumar el valor de USDC y el valor de WETH en USDC
        uint256 totalLpValue = amountUSDC + wethValueInUSDC;

        return totalLpValue;
    }

    function getAmountsFromPosition(uint256 tokenId) internal view returns (uint256 amountUSDC, uint256 amountWETH) {
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);

        // Obtener los parámetros necesarios para calcular las cantidades
        (uint160 sqrtPriceX96, , , , , , ) = uniswapPool.slot0();
        (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) = getSqrtRatios(tokenId);

        // Calcular las cantidades de tokens en la posición
        (amountUSDC, amountWETH) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            liquidity
        );
    }

    function getSqrtRatios(uint256 tokenId) internal view returns (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) {
        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = positionManager.positions(tokenId);

        sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    // Funciones para actualizar direcciones de contratos externos
    function setAavePool(address _aavePool) external onlyOwner {
        aavePool = IPool(_aavePool);
    }

    function setUniswapRouter(address _uniswapRouter) external onlyOwner {
        uniswapRouter = ISwapRouter(_uniswapRouter);
    }

    function setEthUsdPriceFeed(address _priceFeed) external onlyOwner {
        ethUsdPriceFeed = AggregatorV3Interface(_priceFeed);
    }

    // Agregar más funciones setter según sea necesario
}
