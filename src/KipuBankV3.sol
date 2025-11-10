// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;

/*//////////////////////////////////////////////////////////////
                        IMPORTS / INTERFACES
//////////////////////////////////////////////////////////////*/

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Router Uniswap V2 (subset necesario)
interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);

    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

/// @dev Factory Uniswap V2 (para verificar par directo)
interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/*//////////////////////////////////////////////////////////////
                             CONTRATO
//////////////////////////////////////////////////////////////*/

/// @title KipuBankV3
/// @notice Banco DeFi con depósitos generalizados: acepta ETH/USDC/cualquier ERC20 con par directo USDC en UniswapV2, swappea a USDC y acredita al usuario.
/// @dev Preserva seguridad, ownership y patrones de V2, y añade integración Uniswap V2 + bank cap en USDC.
contract KipuBankV3 is ReentrancyGuard, AccessControl {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Límite fijo de retiro por transacción (aplica al token retirado).
    /// @dev Igual que en V2. Para USDC, expresarlo con 6 decimales.
    uint256 public immutable withdrawLimit;

    /// @notice (V2) Cap global en unidades del activo depositado (legacy/no crítico en V3).
    /// @dev Se mantiene para compatibilidad con V2 (no es el cap efectivo en V3).
    uint256 public immutable bankCap;

    /// @notice (V2) Cap global del banco expresado en USD con 8 decimales (legacy).
    /// @dev Se conserva para compatibilidad documental de V2.
    uint256 public bankCapUSD;

    /// @notice Total depositado (legacy V2, mantenido para no romper reporting antiguo).
    uint256 public totalDeposited;

    /// @notice Número de depósitos realizados.
    uint256 public totalDeposits;

    /// @notice Número de retiros realizados.
    uint256 public totalWithdrawals;

    /// @notice Rol de administrador.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Feed Chainlink de ETH/USD (V2). Conservado para compatibilidad.
    AggregatorV3Interface public priceFeed;

    /// @notice Bóvedas por usuario y token. address(0) representa ETH (compatibilidad V2).
    mapping(address => mapping(address => uint256)) private vaults;

    /// @notice (V2) Feeds por token a USD (compatibilidad).
    mapping(address => AggregatorV3Interface) public tokenPriceFeeds;

    /// @notice Dirección del token USDC.
    /// @dev Se asume con 6 decimales.
    address public immutable USDC;

    /// @notice Router Uniswap V2.
    IUniswapV2Router02 public immutable router;

    /// @notice Factory Uniswap V2 para verificar par directo.
    IUniswapV2Factory public immutable factory;

    /// @notice Dirección WETH del router.
    address public immutable WETH;

    /// @notice Bank Cap efectivo en V3 expresado en USDC (6 decimales).
    uint256 public immutable bankCapUSDC;

    /// @notice Total depositado en USDC (6 decimales) contabilizado tras los swaps.
    uint256 public totalDepositedUSDC;

    /*//////////////////////////////////////////////////////////////
                                EVENTOS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitido cuando un usuario deposita (monto registrado en el activo de la bóveda).
    /// @param user Usuario que deposita.
    /// @param amount Monto acreditado (para V3: USDC).
    event Deposited(address indexed user, uint256 amount);

    /// @notice Emitido cuando un usuario retira.
    /// @param user Usuario que retira.
    /// @param amount Monto retirado.
    event Withdrawn(address indexed user, uint256 amount);

    /// @notice Cambio de admin.
    event AdminChanged(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Asignación/actualización de feed de Chainlink por token (compatibilidad V2).
    event TokenFeedSet(address indexed token, address indexed feed);

    /// @notice Swap ejecutado en Uniswap V2.
    /// @param user Usuario que originó el depósito.
    /// @param tokenIn Token de entrada swappeado (address(0) indica ETH).
    /// @param amountIn Monto de entrada recibido.
    /// @param usdcOut Monto de USDC recibido y acreditado (6 decimales).
    event SwapToUSDC(address indexed user, address indexed tokenIn, uint256 amountIn, uint256 usdcOut);

    /*//////////////////////////////////////////////////////////////
                                 ERRORES
    //////////////////////////////////////////////////////////////*/

    error ErrorNotOwner();
    error ErrorDepositoExcedeCap();
    error ErrorRetiroExcedeLimite();
    error ErrorFondosInsuficientes();
    error ErrorTransferenciaFallida();
    error ErrorMontoInvalido();
    error DepositoInvalido();
    error FeedNoDisponible();
    error ParNoDisponible();         // Par directo USDC no disponible.
    error SlippageExcesiva();        // amountOut < amountOutMin.
    error TokenNoSoportado();        // Depósito no soportado.

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _withdrawLimit Límite máximo de retiro por transacción (para USDC usar 6 decimales).
    /// @param _bankCap (legacy V2) cap en "unidades nativas"; se conserva para compatibilidad.
    /// @param _bankCapUSD (legacy V2) cap en USD con 8 decimales; se conserva para compatibilidad.
    /// @param _bankCapUSDC Cap efectivo de V3 en USDC (6 decimales).
    /// @param _priceFeed Dirección del oráculo ETH/USD (compatibilidad V2).
    /// @param _router Dirección del router Uniswap V2.
    /// @param _factory Dirección de la factory Uniswap V2.
    /// @param _usdc Dirección del token USDC (6 decimales).
    constructor(
        uint256 _withdrawLimit,
        uint256 _bankCap,
        uint256 _bankCapUSD,
        uint256 _bankCapUSDC,
        address _priceFeed,
        address _router,
        address _factory,
        address _usdc
    ) {
        require(_router != address(0) && _factory != address(0) && _usdc != address(0), "addr 0");
        withdrawLimit = _withdrawLimit;
        bankCap = _bankCap;
        bankCapUSD = _bankCapUSD;
        bankCapUSDC = _bankCapUSDC;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);

        priceFeed = AggregatorV3Interface(_priceFeed);
        router = IUniswapV2Router02(_router);
        factory = IUniswapV2Factory(_factory);
        USDC = _usdc;
        WETH = 0xdd13E55209Fd76AfE204dBda4007C227904f0a81; // WETH Sepolia
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Valida montos mayores a cero.
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ErrorMontoInvalido();
        _;
    }

    /// @notice Restringe ejecución a ADMIN_ROLE.
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert ErrorNotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                         FUNCIONES PRINCIPALES V3
    //////////////////////////////////////////////////////////////*/

    /// @notice Depositar USDC directamente (sin swap) y acreditar al usuario.
    /// @dev Respeta bank cap en USDC (6 decimales) antes de acreditar.
    /// @param amountUSDC Monto USDC (6 decimales) a depositar.
    function depositUSDC(uint256 amountUSDC) external nonReentrant validAmount(amountUSDC) {
        // Chequeo de cap previo a mover fondos
        if (totalDepositedUSDC + amountUSDC > bankCapUSDC) revert ErrorDepositoExcedeCap();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amountUSDC);

        vaults[msg.sender][USDC] += amountUSDC;
        totalDepositedUSDC += amountUSDC;
        totalDeposits++;

        emit Deposited(msg.sender, amountUSDC);
    }

    /// @notice Depositar ETH; se swappea a USDC vía UniswapV2 y se acredita.
    /// @dev Usa path WETH -> USDC. El usuario provee tolerancia de slippage.
    /// @param minUSDCOut Mínimo USDC aceptado (protección slippage).
    function depositETHAndSwap(uint256 minUSDCOut) external payable nonReentrant validAmount(msg.value) {
        // Previsualizar salida y validar cap
        uint256 expectedOut = _quoteOut(msg.value, WETH, USDC);
        if (expectedOut < minUSDCOut) revert SlippageExcesiva();
        if (totalDepositedUSDC + expectedOut > bankCapUSDC) revert ErrorDepositoExcedeCap();

        address[] memory path= new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            minUSDCOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );

        uint256 usdcOut = amounts[amounts.length - 1];
        vaults[msg.sender][USDC] += usdcOut;
        totalDepositedUSDC += usdcOut;
        totalDeposits++;

        emit SwapToUSDC(msg.sender, address(0), msg.value, usdcOut);
        emit Deposited(msg.sender, usdcOut);
    }

    /// @notice Depositar un ERC20 cualquiera con par directo USDC (UniswapV2), swap a USDC y acreditar.
    /// @dev El depósito en tokens distintos a USDC siempre se swappea a USDC.
    /// @param tokenIn Dirección del token a depositar (no USDC).
    /// @param amountIn Monto del token a depositar.
    /// @param minUSDCOut Mínimo USDC aceptado (protección slippage).
    function depositTokenAndSwap(address tokenIn, uint256 amountIn, uint256 minUSDCOut)
        external
        nonReentrant
        validAmount(amountIn)
    {
        if (tokenIn == address(0)) revert TokenNoSoportado();
        if (tokenIn == USDC) revert TokenNoSoportado();

        // Verificar que exista par directo tokenIn <-> USDC
        if (factory.getPair(tokenIn, USDC) == address(0)) revert ParNoDisponible();

        // Previsualizar salida y validar cap
        uint256 expectedOut = _quoteOut(amountIn, tokenIn, USDC);
        if (expectedOut < minUSDCOut) revert SlippageExcesiva();
        if (totalDepositedUSDC + expectedOut > bankCapUSDC) revert ErrorDepositoExcedeCap();

        // Traer fondos y aprobar router
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(router), 0);
        IERC20(tokenIn).forceApprove(address(router), amountIn);

       address[] memory path= new address[](2);
        path[0] = tokenIn;
        path[1] = USDC;

        uint[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minUSDCOut,
            path,
            address(this),
            block.timestamp + 15 minutes
        );

        uint256 usdcOut = amounts[amounts.length - 1];
        vaults[msg.sender][USDC] += usdcOut;
        totalDepositedUSDC += usdcOut;
        totalDeposits++;

        emit SwapToUSDC(msg.sender, tokenIn, amountIn, usdcOut);
        emit Deposited(msg.sender, usdcOut);
    }

    /*//////////////////////////////////////////////////////////////
                     FUNCIONES PRESERVADAS DE V2
    //////////////////////////////////////////////////////////////*/

    /// @notice Depositar ETH sin argumentos (compat V2).
    /// @dev En V3, se mantiene como entrada pero se recomienda usar depositETHAndSwap().
    function deposit() external payable nonReentrant {
        if (msg.value == 0) revert DepositoInvalido();

        // V3: por diseño todos los depósitos deben consolidarse en USDC.
        // Para preservar interfaz, aquí realizamos el mismo flujo que depositETHAndSwap con minUSDCOut=0.
        uint256 expectedOut = _quoteOut(msg.value, WETH, USDC);
        if (totalDepositedUSDC + expectedOut > bankCapUSDC) revert ErrorDepositoExcedeCap();

       address[] memory path= new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            0, // el usuario no fija slippage en esta ruta "legacy"
            path,
            address(this),
            block.timestamp + 15 minutes
        );

        uint256 usdcOut = amounts[amounts.length - 1];
        vaults[msg.sender][USDC] += usdcOut;
        totalDepositedUSDC += usdcOut;
        totalDeposits++;

        emit SwapToUSDC(msg.sender, address(0), msg.value, usdcOut);
        emit Deposited(msg.sender, usdcOut);
    }

    /// @notice (V2) Depositar token/ETH según parámetro.
    /// @dev En V3, si el token no es USDC ni ETH, se sugiere usar depositTokenAndSwap.
    ///      Mantenemos esta función por compatibilidad; acepta:
    ///      - token==address(0): ETH -> se swappea a USDC
    ///      - token==USDC: se acredita directo
    function depositToken(address token, uint256 amount)
        external
        payable
        nonReentrant
        validAmount(token == address(0) ? msg.value : amount)
    {
        if (token == address(0)) {
            // ETH -> USDC
            uint256 expectedOut = _quoteOut(msg.value, WETH, USDC);
            if (totalDepositedUSDC + expectedOut > bankCapUSDC) revert ErrorDepositoExcedeCap();
            
            address[] memory path= new address[](2);
            path[0] = WETH;
            path[1] = USDC;

            uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
                0,
                path,
                address(this),
                block.timestamp + 15 minutes
            );
            uint256 usdcOut = amounts[amounts.length - 1];

            vaults[msg.sender][USDC] += usdcOut;
            totalDepositedUSDC += usdcOut;
            totalDeposits++;
            emit SwapToUSDC(msg.sender, address(0), msg.value, usdcOut);
            emit Deposited(msg.sender, usdcOut);
        } else if (token == USDC) {
            // USDC directo
            if (totalDepositedUSDC + amount > bankCapUSDC) revert ErrorDepositoExcedeCap();
            IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
            vaults[msg.sender][USDC] += amount;
            totalDepositedUSDC += amount;
            totalDeposits++;
            emit Deposited(msg.sender, amount);
        } else {
            // Para otros tokens en V3: usar depositTokenAndSwap (se conserva compat con error explícito).
            revert TokenNoSoportado();
        }
    }

    /// @notice Retirar USDC desde la bóveda (V3).
    /// @dev Usa el mismo withdrawLimit de V2, pero aplicado a USDC (6 decimales).
    /// @param amountUSDC Monto USDC (6 decimales).
    function withdrawUSDC(uint256 amountUSDC) external nonReentrant validAmount(amountUSDC) {
        if (amountUSDC > withdrawLimit) revert ErrorRetiroExcedeLimite();
        if (vaults[msg.sender][USDC] < amountUSDC) revert ErrorFondosInsuficientes();

        vaults[msg.sender][USDC] -= amountUSDC;
        // Mantener totalWithdrawals para métricas
        totalWithdrawals++;

        IERC20(USDC).safeTransfer(msg.sender, amountUSDC);
        emit Withdrawn(msg.sender, amountUSDC);
    }

    /// @notice (V2) Retiro genérico por token. En V3 sólo tiene sentido para USDC.
    /// @dev Para compatibilidad, se mantiene la firma y validaciones.
    function withdrawToken(address token, uint256 amount) external nonReentrant validAmount(amount) {
        if (amount > withdrawLimit) revert ErrorRetiroExcedeLimite();
        if (vaults[msg.sender][token] < amount) revert ErrorFondosInsuficientes();

        vaults[msg.sender][token] -= amount;
        totalWithdrawals++;

        _safeTransfer(token, msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice (V2) Retirar ETH legacy. En V3, los saldos se consolidan en USDC; esta función se mantiene por compatibilidad.
    function withdraw(uint256 amount) external nonReentrant validAmount(amount) {
        if (amount > withdrawLimit) revert ErrorRetiroExcedeLimite();
        if (vaults[msg.sender][address(0)] < amount) revert ErrorFondosInsuficientes();

        vaults[msg.sender][address(0)] -= amount;
        totalWithdrawals++;

        _safeTransfer(address(0), msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                               VISTAS / UTILS
    //////////////////////////////////////////////////////////////*/

    /// @notice Balance de un usuario para un token específico.
    /// @dev En V3, el saldo principal está en USDC.
    function getVaultBalance(address user, address token) external view returns (uint256) {
        return vaults[user][token];
    }

    /// @notice Precio ETH/USD con 8 decimales (compat V2).
    function getLatestETHPrice() public view returns (int256 price) {
        (, price,,,) = priceFeed.latestRoundData();
    }

    /// @notice (compat V2) Conversión ETH->USD (8 decimales).
    function _ethToUSD(uint256 amountETH) internal view returns (uint256 amountUSD) {
        int256 price = getLatestETHPrice();
        if (price <= 0) revert DepositoInvalido();
        amountUSD = (amountETH * uint256(price)) / 1e18;
    }

    /// @notice (compat V2) Conversión token->USD (8 decimales) usando feed si existe.
    function _tokenToUSD(address token, uint256 amount) internal view returns (uint256 amountUSD) {
        AggregatorV3Interface feed = token == address(0) ? priceFeed : tokenPriceFeeds[token];
        if (address(feed) == address(0)) revert FeedNoDisponible();
        (, int256 price,,,) = feed.latestRoundData();
        if (price <= 0) revert DepositoInvalido();

    uint8 tokenDecimals = token == address(0) ? 18 : IERC20Metadata(token).decimals();
        
        amountUSD = (amount * uint256(price)) / (10 ** tokenDecimals);
    }

    /// @notice Previsualizar salida de swap para validar slippage y bank cap.
    /// @param amountIn Monto de entrada.
    /// @param tokenIn Token de entrada.
    /// @param tokenOut Token de salida (USDC).
    /// @return amountOut Cantidad estimada de salida.
    function _quoteOut(uint256 amountIn, address tokenIn, address tokenOut) internal view returns (uint256 amountOut) {
        address[] memory path= new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint[] memory amounts = router.getAmountsOut(amountIn, path);
        amountOut = amounts[amounts.length - 1];
    }

    /// @notice Transferencia segura de ETH o ERC20 (compat V2).
    function _safeTransfer(address token, address to, uint256 amount) private {
        bool success;
        if (token == address(0)) {
            (success,) = to.call{value: amount}("");
            if (!success) revert ErrorTransferenciaFallida();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Recibe ETH y lo swappea automáticamente a USDC (equivalente a deposit()).
    receive() external payable {
        if (msg.value == 0) revert DepositoInvalido();
        uint256 expectedOut = _quoteOut(msg.value, WETH, USDC);
        if (totalDepositedUSDC + expectedOut > bankCapUSDC) revert ErrorDepositoExcedeCap();

        address[] memory path= new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 usdcOut = amounts[amounts.length - 1];
        vaults[msg.sender][USDC] += usdcOut;
        totalDepositedUSDC += usdcOut;
        totalDeposits++;

        emit SwapToUSDC(msg.sender, address(0), msg.value, usdcOut);
        emit Deposited(msg.sender, usdcOut);
    }

    /// @notice Fallback payable: también interpreta ETH entrante como depósito con swap a USDC.
    fallback() external payable {
        if (msg.value == 0) revert DepositoInvalido();
        uint256 expectedOut = _quoteOut(msg.value, WETH, USDC);
        if (totalDepositedUSDC + expectedOut > bankCapUSDC) revert ErrorDepositoExcedeCap();

        address[] memory path= new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        uint[] memory amounts = router.swapExactETHForTokens{value: msg.value}(
            0,
            path,
            address(this),
            block.timestamp + 15 minutes
        );
        uint256 usdcOut = amounts[amounts.length - 1];
        vaults[msg.sender][USDC] += usdcOut;
        totalDepositedUSDC += usdcOut;
        totalDeposits++;

        emit SwapToUSDC(msg.sender, address(0), msg.value, usdcOut);
        emit Deposited(msg.sender, usdcOut);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN / SETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transferir la administración del contrato a otra cuenta.
    function transferOwnership(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ErrorNotOwner();
        address oldAdmin = msg.sender;
        grantRole(ADMIN_ROLE, newAdmin);
        revokeRole(ADMIN_ROLE, msg.sender);
        emit AdminChanged(oldAdmin, newAdmin);
    }

    /// @notice Asignar/actualizar el feed de Chainlink para un token (compat V2).
    function setTokenPriceFeed(address token, address feed) external onlyAdmin {
        if (feed == address(0)) revert FeedNoDisponible();
        tokenPriceFeeds[token] = AggregatorV3Interface(feed);
        emit TokenFeedSet(token, feed);
    }
}
