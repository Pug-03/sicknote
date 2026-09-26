// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EmergencySickLeave — "ใบลาป่วยฉุกเฉิน / พอยต์คนสู้ชีวิต"
 * @notice โมดูลที่ 3 ของโปรเจกต์ Ultimate Sleep-Deprived Dev Assistant
 *         ให้ dev ที่อดนอนมา claim "ใบลาป่วยฉุกเฉิน" ได้ 1 สิทธิ์ต่อ 1 address
 *         พร้อมสะสม "พอยต์คนสู้ชีวิต" (survivorPoints)
 * @dev เขียนแบบ self-contained ไม่ต้อง import OpenZeppelin
 *      deploy ได้ทันทีบน Remix + Avalanche Fuji (chainId 43113)
 */
contract EmergencySickLeave {
    // ---------------------------------------------------------------
    // ส่วนที่ 1: Custom Errors (ประหยัด gas กว่า require(string))
    // ---------------------------------------------------------------

    error AlreadyClaimed(address claimer, uint40 claimedAt); // กดซ้ำ = revert ทันที
    error ReentrantCall();                                   // ตรวจจับ re-entrancy
    error ContractPaused();                                  // owner สั่งหยุดชั่วคราว
    error NotOwner();                                        // ไม่ใช่เจ้าของสัญญา
    error ReasonTooLong(uint256 length, uint256 maxLength);  // เหตุผลยาวเกิน
    error NothingToRevoke(address target);                   // ยังไม่เคย claim

    // ---------------------------------------------------------------
    // ส่วนที่ 2: ค่าคงที่ (constant = ฝังใน bytecode ไม่กิน storage)
    // ---------------------------------------------------------------

    /// @notice พอยต์ที่ได้ต่อการ claim 1 ครั้ง
    uint16 public constant POINTS_PER_CLAIM = 100;

    /// @notice ความยาวสูงสุดของข้อความเหตุผล (กันคนยัด data ยาว ๆ เผา gas)
    uint256 public constant MAX_REASON_LENGTH = 140;

    // ค่า guard สำหรับ re-entrancy: ใช้ 1/2 ไม่ใช้ bool
    // เพราะ bool false->true เป็น cold write (20,000 gas) ส่วน 1->2 เป็น warm write (~2,900 gas)
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    // ---------------------------------------------------------------
    // ส่วนที่ 3: Data structures
    // ---------------------------------------------------------------

    /**
     * @notice บันทึกใบลา 1 ใบ
     * @dev จัด field ให้ pack ลง 1 storage slot (40 + 16 + 32 = 88 bits < 256 bits)
     *      ส่วน string reason อยู่ slot แยกโดยอัตโนมัติ
     */
    struct LeaveRecord {
        uint40 claimedAt;   // timestamp ที่ claim (uint40 พอถึงปี ค.ศ. 36812)
        uint16 points;      // พอยต์คนสู้ชีวิตที่ได้รับ
        uint32 ticketId;    // เลขที่ใบลา เริ่มจาก 1
        string reason;      // เหตุผล เช่น "debug prod ถึงตี 4"
    }

    // ---------------------------------------------------------------
    // ส่วนที่ 4: State variables
    // ---------------------------------------------------------------

    /// @notice เจ้าของสัญญา (ผู้ deploy) — มีสิทธิ์ pause / revoke
    address public owner;

    /// @notice true = หยุดรับ claim ชั่วคราว
    bool public paused;

    /// @notice จำนวนใบลาที่ออกไปแล้วทั้งหมด (ใช้เป็นตัวรัน ticketId ด้วย)
    uint32 public totalTickets;

    /// @notice ธงกันกดซ้ำ — หัวใจหลักของโมดูลนี้
    mapping(address => bool) public hasClaimed;

    /// @notice ข้อมูลใบลาของแต่ละ address
    mapping(address => LeaveRecord) private _records;

    /// @notice ยอดพอยต์คนสู้ชีวิตสะสม (แยกจาก record เพื่อให้ revoke แล้วพอยต์ยังอยู่ได้ถ้าต้องการ)
    mapping(address => uint256) public survivorPoints;

    /// @notice ลิสต์ address ทุกคนที่เคย claim (สำหรับทำ leaderboard บน frontend)
    address[] private _claimers;

    // สถานะ re-entrancy guard
    uint256 private _status = _NOT_ENTERED;

    // ---------------------------------------------------------------
    // ส่วนที่ 5: Events (frontend subscribe เพื่ออัปเดต UI แบบเรียลไทม์)
    // ---------------------------------------------------------------

    event SickLeaveClaimed(
        address indexed claimer,
        uint32 indexed ticketId,
        uint16 points,
        uint40 claimedAt,
        string reason
    );
    event ClaimRevoked(address indexed target, uint32 indexed ticketId);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---------------------------------------------------------------
    // ส่วนที่ 6: Modifiers
    // ---------------------------------------------------------------

    /**
     * @dev Re-entrancy Guard แบบ manual (ตรรกะเดียวกับ OpenZeppelin ReentrancyGuard)
     *      ถ้า external call ย้อนกลับเข้ามาระหว่างที่ฟังก์ชันยังทำงานไม่จบ -> revert
     */
    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;   // ล็อกก่อนเข้า body
        _;
        _status = _NOT_ENTERED; // ปลดล็อกหลังทำงานเสร็จ
    }

    /// @dev ต้องไม่ถูก pause อยู่
    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    /// @dev เฉพาะ owner
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------
    // ส่วนที่ 7: Constructor
    // ---------------------------------------------------------------

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ---------------------------------------------------------------
    // ส่วนที่ 8: ฟังก์ชันหลัก — Claim สิทธิ์ใบลาป่วยฉุกเฉิน
    // ---------------------------------------------------------------

    /**
     * @notice Claim "ใบลาป่วยฉุกเฉิน" + รับพอยต์คนสู้ชีวิต 100 แต้ม
     * @param reason เหตุผลการลา (<= 140 ตัวอักษร) เช่น "แก้ bug prod ถึงตี 4"
     * @return ticketId เลขที่ใบลาที่ได้รับ
     *
     * @dev ชั้นป้องกันการกดซ้ำ 2 ชั้น:
     *      1) hasClaimed[msg.sender] — 1 address claim ได้ครั้งเดียวตลอดกาล กดซ้ำ revert
     *      2) nonReentrant — กัน contract ที่พยายามเรียกวนซ้ำใน tx เดียว
     *      ใช้ Checks-Effects-Interactions: เช็กเงื่อนไข -> เขียน state -> emit event
     *      (ฟังก์ชันนี้ไม่มี external call เลย จึงไม่มีช่องให้ reenter อยู่แล้ว
     *       แต่ใส่ guard ไว้เป็น defense-in-depth เผื่ออนาคตเพิ่ม hook/NFT mint)
     */
    function claimSickLeave(string calldata reason)
        external
        nonReentrant
        whenNotPaused
        returns (uint32 ticketId)
    {
        // --- CHECKS ---
        // ด่านที่ 1: เคย claim ไปแล้วหรือยัง? ถ้าเคย -> revert ทันที พร้อมบอกเวลาที่เคยกด
        if (hasClaimed[msg.sender]) {
            revert AlreadyClaimed(msg.sender, _records[msg.sender].claimedAt);
        }

        // ด่านที่ 2: กันข้อความยาวเกินกำหนด
        uint256 len = bytes(reason).length;
        if (len > MAX_REASON_LENGTH) {
            revert ReasonTooLong(len, MAX_REASON_LENGTH);
        }

        // --- EFFECTS ---
        hasClaimed[msg.sender] = true;              // ปิดประตูก่อนทำอย่างอื่น
        ticketId = ++totalTickets;                  // ออกเลขที่ใบลา (เริ่มจาก 1)
        uint40 now40 = uint40(block.timestamp);

        _records[msg.sender] = LeaveRecord({
            claimedAt: now40,
            points: POINTS_PER_CLAIM,
            ticketId: ticketId,
            reason: reason
        });

        survivorPoints[msg.sender] += POINTS_PER_CLAIM;
        _claimers.push(msg.sender);

        // --- INTERACTIONS (ที่นี่มีแค่ event ไม่มี external call) ---
        emit SickLeaveClaimed(msg.sender, ticketId, POINTS_PER_CLAIM, now40, reason);
    }

    // ---------------------------------------------------------------
    // ส่วนที่ 9: View functions (frontend เรียกฟรี ไม่เสีย gas)
    // ---------------------------------------------------------------

    /// @notice address นี้ claim ได้อีกไหม (ใช้ enable/disable ปุ่มบน UI)
    function canClaim(address user) external view returns (bool) {
        return !paused && !hasClaimed[user];
    }

    /**
     * @notice ดึงใบลาของ address ที่ระบุ
     * @dev คืนค่าเป็น tuple แบน ๆ ให้ ethers.js อ่านง่าย
     */
    function getRecord(address user)
        external
        view
        returns (
            bool claimed,
            uint32 ticketId,
            uint40 claimedAt,
            uint16 points,
            string memory reason
        )
    {
        LeaveRecord storage r = _records[user];
        return (hasClaimed[user], r.ticketId, r.claimedAt, r.points, r.reason);
    }

    /// @notice จำนวนคนที่เคย claim ทั้งหมด
    function totalClaimers() external view returns (uint256) {
        return _claimers.length;
    }

    /**
     * @notice ดึงลิสต์ผู้ claim แบบแบ่งหน้า (กัน out-of-gas เมื่อคนเยอะ)
     * @param offset เริ่มจาก index ไหน
     * @param limit เอากี่รายการ
     */
    function getClaimers(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory page)
    {
        uint256 total = _claimers.length;
        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _claimers[i];
        }
    }

    // ---------------------------------------------------------------
    // ส่วนที่ 10: ฟังก์ชันสำหรับ owner (admin)
    // ---------------------------------------------------------------

    /// @notice เปิด/ปิดการรับ claim ชั่วคราว (เช่นตอนแจกสิทธิ์รอบใหม่ยังไม่พร้อม)
    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    /**
     * @notice ยกเลิกใบลาของ address ที่ระบุ ทำให้ claim ใหม่ได้อีกครั้ง
     * @dev ใช้ตอน demo / ทดสอบซ้ำ หรือกรณีออกใบลาผิด
     *      หมายเหตุ: พอยต์ที่สะสมไว้ถูกหักคืนด้วย เพื่อให้ยอดตรงกับจำนวนใบลาจริง
     */
    function revokeClaim(address target) external onlyOwner {
        if (!hasClaimed[target]) revert NothingToRevoke(target);

        uint32 ticketId = _records[target].ticketId;
        uint16 pts = _records[target].points;

        hasClaimed[target] = false;
        delete _records[target];

        // หักพอยต์คืน (ใช้ unchecked ไม่ได้ ปล่อยให้ checked math กัน underflow)
        if (survivorPoints[target] >= pts) {
            survivorPoints[target] -= pts;
        } else {
            survivorPoints[target] = 0;
        }

        emit ClaimRevoked(target, ticketId);
    }

    /// @notice โอนสิทธิ์เจ้าของสัญญา
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO_ADDRESS");
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
    }

    // ---------------------------------------------------------------
    // ส่วนที่ 11: กันคนส่ง AVAX เข้ามาโดยไม่ตั้งใจ
    // ---------------------------------------------------------------

    /// @dev ไม่มี receive()/fallback() ที่ payable -> ส่งเงินเข้ามาจะ revert เอง
    ///      สัญญานี้ไม่ถือเงิน จึงไม่มีความเสี่ยงเรื่อง fund drain
}
