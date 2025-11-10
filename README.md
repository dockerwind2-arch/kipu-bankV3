# 🏦 KipuBankV3  

Contrato inteligente en **Solidity** que convierte a KipuBank en una aplicación **DeFi avanzada**, capaz de aceptar **ETH, USDC y cualquier token ERC20** con par directo a USDC en **Uniswap V2**, intercambiándolos automáticamente por USDC y acreditando el resultado al balance del usuario.

---

## 📖 Descripción general

KipuBankV3 evoluciona la arquitectura de KipuBankV2 hacia un sistema **interoperable, seguro y extensible**, con las siguientes mejoras:

### 🚀 Mejoras clave

- **Integración con Uniswap V2:**  
  Cualquier token soportado con par USDC puede depositarse y será intercambiado automáticamente a USDC mediante el router de Uniswap.

- **Consolidación de activos en USDC:**  
  Todos los depósitos —ya sean ETH o tokens ERC20— se convierten internamente a USDC.  
  Esto simplifica la gestión de balances y la contabilidad del banco.

- **Límite global (`bankCapUSDC`):**  
  Controla el monto total en USDC que el banco puede custodiar, garantizando estabilidad y previsibilidad del sistema.

- **Resguardo de la lógica original (V2):**  
  Mantiene todas las funcionalidades de V2:  
  depósitos, retiros, roles de administración y feeds de Chainlink.

- **Seguridad mejorada:**  
  Se utilizan `ReentrancyGuard`, `SafeERC20`, `AccessControl` y validaciones estrictas de slippage y límites.

---

## 📁 Estructura del repositorio
```bash
kipu-bank-v3/
├─ src/
│  └─ KipuBankV3.sol
├─ test/
│  └─ KipuBankV3.t.sol
├─ lib/
│  ├─ openzeppelin-contracts/
│  ├─ forge-std/
│  └─ chainlink-brownie-contracts/
├─ foundry.toml
└─ README.md

---
```
## ⚙️ Cómo compilar y probar (Foundry)

### 🔧 Requisitos previos
- **Foundry** instalado (`forge --version`)
- **Git Bash o WSL** en Windows
- **Solidity >=0.8.20**

### 🧩 Instalación
```bash
forge install foundry-rs/forge-std --no-git
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-git
forge install smartcontractkit/chainlink-brownie-contracts --no-git

## ⚙️ Compilación
forge build

🧪 Ejecución de tests
forge test -vvv

✅ Resultado esperado:
Ran 4 tests for test/KipuBankV3.t.sol:KipuBankV3Test
[PASS] testDepositUSDC()
[PASS] testWithdrawUSDC()
[PASS] testOwnerIsAdmin()
[PASS] testExpectRevert_WhenWithdrawWithoutFunds()
Suite result: ok. 4 passed; 0 failed; 0 skipped

📈 Cobertura
Estos tests alcanzan una cobertura de ~55 %, cubriendo depósitos, retiros, ownership y manejo de errores.

📦 Despliegue en testnet (ejemplo Sepolia)
Constructor
Parámetro	Ejemplo	Descripción
_withdrawLimit	1000000000 (1,000 USDC)	Límite máximo de retiro por transacción
_bankCap	0	Cap legacy (no usado en V3)
_bankCapUSD	0	Cap legacy (no usado en V3)
_bankCapUSDC	100000000000	Cap efectivo en USDC (6 decimales)
_priceFeed	0x694AA1769357215DE4FAC081bf1f309aDC325306	ETH/USD feed de Chainlink
_router	Dirección del router Uniswap V2 (ej. 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D)	
_factory	Dirección de la factory Uniswap V2	
_usdc	Dirección de contrato USDC en la red elegida	

📦 Despliegue manual
Compilar y verificar:
forge build

📦Deploy con Forge:
forge create src/KipuBankV3.sol:KipuBankV3 --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --constructor-args 1000e6 0 0 1000000000 0xFeed 0xRouter 0xFactory 0xUSDC
```

### 📡 Funciones principales
- **depositUSDC(uint256 amount)**	Deposita directamente USDC en el banco.
- **depositETHAndSwap(uint256 minUSDCOut)**	Deposita ETH, lo intercambia por USDC y lo acredita.
- **depositTokenAndSwap(address token, uint256 amount, uint256 minUSDCOut)** Deposita un token ERC20 (con par directo a USDC) y lo swappea automáticamente.
- **withdrawUSDC(uint256 amount)**	Retira fondos en USDC, respetando withdrawLimit.
- **transferOwnership(address newAdmin)**	Transfiere el rol de administrador.
- **setTokenPriceFeed(address token, address feed)**	Asigna un feed Chainlink (compatibilidad V2).

### 🔒 Seguridad y buenas prácticas
- **ReentrancyGuard:** evita ataques de reentrada en depósitos y retiros.
- **SafeERC20:** garantiza transferencias seguras de tokens ERC20.
- **Slippage control:** validación de minUSDCOut en swaps.
- **BankCap efectivo:** no permite superar el límite global en USDC.
- **AccessControl:** gestión de roles y transferencia segura de ownership.
- **Errores personalizados:** mejor uso de gas y trazabilidad clara.

### ⚠️ Análisis de amenazas
- **Riesgo	Mitigación**
- **Reentrancy	nonReentrant en funciones externas críticas**
- **Slippage / Front-running	Parámetro minUSDCOut y verificación previa expectedOut**
- **Manipulación de precios	Uso de Chainlink feeds para referencia externa**
- **Límite de liquidez	bankCapUSDC evita sobrecapitalización**
- **Oráculos falsos / routers maliciosos	Admin puede configurar feeds y direcciones con validaciones**
- **Gas alto o fallas de swap	Validación previa y revert seguro**
- **Owner comprometido	transferOwnership controlado por rol ADMIN_ROLE**

### 💡 Decisiones de diseño
- **Consolidar todos los depósitos en USDC simplifica la gestión y reduce la exposición a tokens volátiles.**
- **Mantener compatibilidad con KipuBankV2 asegura interoperabilidad y migración sencilla.**
- **Se mantiene la firma de las funciones legacy (deposit, withdraw, etc.) para backward compatibility.**
- **Se evita lógica on-chain innecesaria (p. ej. precios dinámicos) y se delega todo a Chainlink + Uniswap.**

### 🧪 Estrategia de testing
**Herramientas:**
- **Foundry (forge) con forge-std**
- **Mocks locales para USDC, Router, Factory y Chainlink**

**Casos cubiertos:**
**Creación de contrato y rol de admin ✅**
**Depósito en USDC ✅**
**Retiro en USDC ✅**
**Reversión por fondos insuficientes ✅**

Estos cubren los flujos más críticos y demuestran la correcta gestión de balances y límites.


### 🧱 Próximos pasos
- **Agregar pruebas de integración con Uniswap reales.**
- **Implementar fuzz testing.**
- **Incorporar herramientas de auditoría automática (Slither/Mythril).**
- **Añadir un dashboard en frontend para visualizar balances y límites en tiempo real.**

### 📍 Dirección de contrato (si desplegado)
- 🧭 **Red:** Sepolia (Testnet)
- ✅ **Contrato verificado:** [0x7adA18747Cbd3484995Bd1d60c65A96483c5f351](https://sepolia.etherscan.io/address/0x7adA18747Cbd3484995Bd1d60c65A96483c5f351#code)
- 🧾 **Tx de Deploy:** [0x772798105cb4740cdb39e9883a69ddccbdd4e12127ffee3bc4e4bac9f1253750](https://sepolia.etherscan.io/tx/0x772798105cb4740cdb39e9883a69ddccbdd4e12127ffee3bc4e4bac9f1253750)
- 👤 **Owner actual:** `0xd2D7b6107E1bfDcc98AA9744Fd6ed640816348a3`
- 📘 **Repositorio:** [GitHub – kipu-bank-v3](https://github.com/dockerwind2-arch/kipu-bank-v3)
