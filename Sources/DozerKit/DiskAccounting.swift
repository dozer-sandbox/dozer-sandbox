import Darwin
import Foundation

/// 587: who shares what, on disk — every disk file of a store measured from APFS's own extent map,
/// ported from the 586 probe's `Measure.swift` (586 Q5: exact to 0.1 MiB against APFS's private
/// size and against the volume's free space; ~50 ms for a 49-disk store).
///
/// 1. Each file's data ranges (`lseek` `SEEK_DATA`/`SEEK_HOLE`) are mapped to physical offsets on
///    the APFS container with `fcntl(F_LOG2PHYS_EXT)`. Two files share a byte exactly when they map
///    it to the same physical offset — an APFS clone shares its source's extents until one is written.
/// 2. A sweep over the physical intervals of all the files gives, per file, the bytes only it
///    references (`unique` — what deleting it frees), the bytes it shares with its lineage parent,
///    and the store's union (what it really occupies).
/// 3. APFS's `ATTR_CMNEXT_PRIVATESIZE` is recorded beside it as the cross-check.
///
/// Measure STOPPED disks: a running VM's unflushed writes have no physical address yet. The
/// physical offsets are the APFS container's, so every file must be on one volume. APFS snapshots
/// (Time Machine's local ones too) hold blocks outside the file set; both numbers count those as
/// the file's own.
public enum DiskAccounting {
    public struct Extent: Sendable, Equatable, Codable {
        public var logical: Int64
        public var physical: Int64
        public var length: Int64
    }

    public enum Kind: String, Sendable, Codable {
        /// `images/bases/…` — a flattened OCI base.
        case base
        /// `images/<name>/<key12>/` — a baked image (parent: its base).
        case image
        /// `images/custom/…` (parent: the image its sandbox came from).
        case customImage
        /// `golden/…` — a prepared disk (the lab sandbox's), or the e2fsck helper's.
        case preparedDisk
        /// A sandbox's root disk (parent: its image) and state disk.
        case sandboxRoot, sandboxState
        /// A restore point's root / state disk (parent: the image the sandbox came from).
        case restorePointRoot, restorePointState
        /// Anything else in the store (the guest init disk, a bake's scratch disk).
        case other
    }

    public enum GarbageSource: String, Sendable, Codable {
        /// Exact: the file's data lying in blocks ext4's bitmaps say are free (a cleanly unmounted disk).
        case ext4FreeBlocks
        /// Estimated: allocated − the guest's `df` used at its last Stop / Hibernate (a disk not
        /// cleanly unmounted). `df` leaves out ext4's own metadata, so this reads a little high.
        case guestDF
    }

    /// One disk file, measured.
    public struct DiskUsage: Sendable {
        public var url: URL
        public var kind: Kind
        /// A readable name: `pi@bf46815674ce`, `base f97ac66c1d54`, `sandbox agent-pi`, …
        public var name: String
        /// The sandbox it belongs to (sandbox and restore-point disks).
        public var sandbox: String?
        /// Its lineage parent's disk, when that is in the store.
        public var parent: URL?
        public var apparentBytes: Int64
        public var allocatedBytes: Int64
        /// Bytes no other file of the store references — what deleting this file frees.
        public var uniqueBytes: Int64
        /// Bytes shared with `parent` (nil without one).
        public var sharedWithParentBytes: Int64?
        /// APFS's own private size (the cross-check), nil if the volume does not report it.
        public var privateBytes: Int64?
        public var extents: Int
        /// Extents per GiB of data — fragmentation. 586: no threshold is needed (1000/GiB cost nothing).
        public var extentsPerGiB: Double
        /// What the guest held at its last Stop / Hibernate (`df`), for sandbox disks.
        public var guestUsedBytes: Int64?
        /// The host file's allocation beyond what the file system holds (see `GarbageSource`).
        public var garbageBytes: Int64?
        public var garbageSource: GarbageSource?
    }

    public struct Report: Sendable {
        public var disks: [DiskUsage]
        /// Bytes all of the store's disks occupy together (shared blocks counted once).
        public var unionBytes: Int64
        public var milliseconds: Double
        public func disk(_ url: URL) -> DiskUsage? { disks.first { $0.url.standardizedFileURL.path == url.standardizedFileURL.path } }
        public func disks(of kind: Kind) -> [DiskUsage] { disks.filter { $0.kind == kind } }
    }

    // MARK: the store

    /// Every disk file of the store at `store`: bases, images, custom images, prepared disks,
    /// sandboxes' root and state disks, restore points, and anything else ending in `.ext4`.
    public static func measure(store: URL) throws -> Report {
        let t0 = ContinuousClock.now
        let fm = FileManager.default
        var found: [(url: URL, kind: Kind, name: String, sandbox: String?, parent: URL?, guestUsed: Int64?)] = []
        let layout = StoreLayout(root: store, name: "_")
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        func ls(_ u: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).sorted() }
        let baker = ImageBaker(storeRoot: store)
        for b in baker.allBases() where exists(b.root) {
            found.append((b.root, .base, "base \(b.key.prefix(12))", nil, nil, nil))
        }
        for name in ls(store.appendingPathComponent("images")) where !ImageSpec.reservedNames.contains(name) {
            let dir = store.appendingPathComponent("images/\(name)")
            for k in ls(dir) {
                let d = dir.appendingPathComponent(k)
                guard let data = try? Data(contentsOf: d.appendingPathComponent("manifest.json")),
                      let m = try? ImageBaker.decoder.decode(ImageManifest.self, from: data) else { continue }
                let root = d.appendingPathComponent("root.ext4")
                guard exists(root) else { continue }
                let parent = m.parent.flatMap { baker.cachedBase($0)?.root }
                found.append((root, .image, "\(name)@\(m.key.prefix(12))", nil, parent, nil))
            }
        }
        for c in layout.customImages() {
            let root = layout.customImageDirectory(c.key).appendingPathComponent("root.ext4")
            guard exists(root) else { continue }
            found.append((root, .customImage, "custom:\(c.key)", nil, c.baseImage.flatMap(layout.imageDisk(forKey:)), nil))
        }
        for g in ls(layout.goldenDirectory) where g.hasSuffix(".ext4") {
            found.append((layout.goldenDirectory.appendingPathComponent(g), .preparedDisk, "prepared \(g)", nil, nil, nil))
        }
        for s in ls(store.appendingPathComponent("sandboxes")) {
            let sl = StoreLayout(root: store, name: s)
            let p = PersistedSandbox.read(from: sl.persistedState)
            let image = p?.rootImage.flatMap(layout.imageDisk(forKey:))
            if exists(sl.rootfs) {
                found.append((sl.rootfs, .sandboxRoot, "sandbox \(s)", s, image, p?.guestUsedMiB.map { Int64($0 * 1_048_576) }))
            }
            if exists(sl.stateDisk) {
                found.append((sl.stateDisk, .sandboxState, "sandbox \(s) (state)", s, nil, p?.stateGuestUsedMiB.map { Int64($0 * 1_048_576) }))
            }
            for rp in sl.restorePoints() {
                let d = sl.restorePointDirectory(rp.id)
                let rpImage = rp.sourceImage.flatMap(layout.imageDisk(forKey:))
                if exists(d.appendingPathComponent("root.ext4")) {
                    found.append((d.appendingPathComponent("root.ext4"), .restorePointRoot, "restore point \(rp.name) of \(s)", s, rpImage, nil))
                }
                if exists(d.appendingPathComponent("state.ext4")) {
                    found.append((d.appendingPathComponent("state.ext4"), .restorePointState, "restore point \(rp.name) of \(s) (state)", s, nil, nil))
                }
            }
        }
        let known = Set(found.map { $0.url.standardizedFileURL.path })
        if exists(layout.initfs) { found.append((layout.initfs, .other, "guest init disk", nil, nil, nil)) }
        for c in ls(store.appendingPathComponent("containers")) {
            let d = store.appendingPathComponent("containers/\(c)")
            for f in ls(d) where f.hasSuffix(".ext4") && !known.contains(d.appendingPathComponent(f).standardizedFileURL.path) {
                found.append((d.appendingPathComponent(f), .other, "containers/\(c)/\(f)", nil, nil, nil))
            }
        }

        let lists = try found.map { try extents(of: $0.url) }
        let index = Dictionary(found.enumerated().map { ($0.element.url.standardizedFileURL.path, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let parents = found.map { $0.parent.flatMap { index[$0.standardizedFileURL.path] } }
        let sweep = Self.sweep(lists, parents: parents)
        var disks: [DiskUsage] = []
        for (i, f) in found.enumerated() {
            let (apparent, allocated) = ImageBaker.sizes(f.url)
            let data = lists[i].reduce(Int64(0)) { $0 + $1.length }
            var u = DiskUsage(url: f.url, kind: f.kind, name: f.name, sandbox: f.sandbox, parent: parents[i] == nil ? nil : f.parent,
                              apparentBytes: apparent, allocatedBytes: allocated, uniqueBytes: sweep.unique[i],
                              sharedWithParentBytes: parents[i] == nil ? nil : sweep.sharedWithParent[i],
                              privateBytes: privateSize(f.url), extents: lists[i].count,
                              extentsPerGiB: data > 0 ? Double(lists[i].count) / (Double(data) / 1_073_741_824) : 0,
                              guestUsedBytes: f.guestUsed, garbageBytes: nil, garbageSource: nil)
            if [.sandboxRoot, .sandboxState, .restorePointRoot, .restorePointState, .image, .customImage, .preparedDisk, .base].contains(f.kind) {
                if let g = try? garbage(of: f.url, extents: lists[i]) {
                    u.garbageBytes = g
                    u.garbageSource = .ext4FreeBlocks
                } else if let used = f.guestUsed {
                    u.garbageBytes = max(0, allocated - used)
                    u.garbageSource = .guestDF
                }
            }
            disks.append(u)
        }
        return Report(disks: disks, unionBytes: sweep.union, milliseconds: milliseconds(since: t0))
    }

    // MARK: files

    /// Per-file unique bytes and bytes shared between named pairs, for any set of files on one
    /// volume (`pairs`: (i, j) → shared bytes).
    public struct ShareView: Sendable {
        public var files: [URL]
        public var allocated: [Int64]
        public var unique: [Int64]
        public var union: Int64
        public var pairs: [Pair: Int64]
        public struct Pair: Hashable, Sendable { public var a: Int; public var b: Int }
        public func shared(_ i: Int, _ j: Int) -> Int64 { pairs[Pair(a: min(i, j), b: max(i, j))] ?? 0 }
    }

    public static func share(_ files: [URL]) throws -> ShareView {
        let lists = try files.map { try extents(of: $0) }
        let s = sweep(lists, parents: files.map { _ in nil }, allPairs: true)
        return ShareView(files: files, allocated: lists.map { $0.reduce(0) { $0 + $1.length } }, unique: s.unique, union: s.union, pairs: s.pairs)
    }

    /// Data extents of a file with their physical device offsets (merged when contiguous in both).
    public static func extents(of url: URL) throws -> [Extent] {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw EXT4Inspector.InspectError.unreadable(url.path) }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let size = Int64(st.st_size)
        var out: [Extent] = []
        var off: Int64 = 0
        // struct log2phys (#pragma pack(4)): u32 l2p_flags, off_t l2p_contigbytes, off_t l2p_devoffset.
        var buf = [UInt8](repeating: 0, count: 20)
        while off < size {
            let ds = lseek(fd, off, SEEK_DATA)
            if ds < 0 { break }                          // ENXIO: no data after `off`
            var he = lseek(fd, ds, SEEK_HOLE)
            if he < 0 || he > size { he = size }
            var cur = ds
            while cur < he {
                let want = he - cur
                buf.withUnsafeMutableBytes { p in
                    p.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
                    p.storeBytes(of: want, toByteOffset: 4, as: Int64.self)
                    p.storeBytes(of: cur, toByteOffset: 12, as: Int64.self)
                }
                guard buf.withUnsafeMutableBytes({ fcntl(fd, F_LOG2PHYS_EXT, $0.baseAddress!) }) == 0 else {
                    throw EXT4Inspector.InspectError.unreadable("\(url.path): F_LOG2PHYS_EXT at \(cur): \(String(cString: strerror(errno)))")
                }
                let (contig, dev) = buf.withUnsafeBytes { ($0.loadUnaligned(fromByteOffset: 4, as: Int64.self), $0.loadUnaligned(fromByteOffset: 12, as: Int64.self)) }
                let len = min(max(contig, 0), want)
                if len <= 0 { cur += 4096; continue }    // never loop forever
                if var last = out.last, last.logical + last.length == cur, last.physical + last.length == dev {
                    last.length += len
                    out[out.count - 1] = last
                } else {
                    out.append(Extent(logical: cur, physical: dev, length: len))
                }
                cur += len
            }
            off = he
        }
        return out
    }

    /// APFS's private size: the bytes of `url` no other file references (nil if unsupported).
    public static func privateSize(_ url: URL) -> Int64? {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.forkattr = attrgroup_t(0x0000_0008)            // ATTR_CMNEXT_PRIVATESIZE
        var buf = [UInt8](repeating: 0, count: 64)
        let r = getattrlist(url.path, &al, &buf, buf.count, UInt32(0x0000_0020))   // FSOPT_ATTR_CMN_EXTENDED
        guard r == 0 else { return nil }
        return buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }

    /// The file's data in blocks ext4 says are free — exact garbage, for a cleanly unmounted ext4
    /// disk (throws otherwise).
    public static func garbage(of url: URL, extents given: [Extent]? = nil) throws -> Int64 {
        total(try garbageRanges(of: url, extents: given))
    }

    /// Where that garbage is: the file's data ranges ∩ ext4's free ranges.
    static func garbageRanges(of url: URL, extents given: [Extent]? = nil) throws -> [(Int64, Int64)] {
        let i = try EXT4Inspector(url)
        guard i.isClean else { throw EXT4Inspector.InspectError.unsupported("\(url.lastPathComponent) was not cleanly unmounted") }
        let data = try (given ?? extents(of: url)).map { ($0.logical, $0.length) }
        return intersect(merge(data), try i.freeRanges())
    }

    // MARK: groups (595)

    /// 595: what deleting a GROUP of files frees — the bytes referenced only by files of that group
    /// (an image's keys together, a sandbox's disks together, a selection of items), per group, for
    /// files on one volume. `groups[i]` is file i's group. The same sweep as `measure`'s: a byte is
    /// freed by deleting group g exactly when every file mapping it is in g.
    public static func exclusive(_ lists: [[Extent]], groups: [Int]) -> (freed: [Int: Int64], union: Int64) {
        precondition(lists.count == groups.count)
        var ev: [(pos: Int64, delta: Int32, file: Int)] = []
        ev.reserveCapacity(lists.reduce(0) { $0 + $1.count } * 2)
        for (i, l) in lists.enumerated() {
            for e in l where e.length > 0 { ev.append((e.physical, 1, i)); ev.append((e.physical + e.length, -1, i)) }
        }
        ev.sort { $0.pos < $1.pos }
        var counts = [Int32](repeating: 0, count: lists.count)
        var active = Set<Int>()
        var freed: [Int: Int64] = [:]
        var union: Int64 = 0
        var prev: Int64 = 0
        var k = 0
        while k < ev.count {
            let pos = ev[k].pos
            let len = pos - prev
            if !active.isEmpty, len > 0 {
                union += len
                let g = groups[active.first!]
                if active.allSatisfy({ groups[$0] == g }) { freed[g, default: 0] += len }
            }
            while k < ev.count, ev[k].pos == pos {
                let i = ev[k].file
                counts[i] += ev[k].delta
                if counts[i] > 0 { active.insert(i) } else { active.remove(i) }
                k += 1
            }
            prev = pos
        }
        return (freed, union)
    }

    /// The extents of each file (an unreadable file maps nothing — it then counts as its allocation
    /// elsewhere; the caller decides).
    public static func extentLists(_ urls: [URL]) -> [[Extent]] { urls.map { (try? extents(of: $0)) ?? [] } }

    // MARK: the sweep

    struct Sweep {
        var unique: [Int64]
        var sharedWithParent: [Int64]
        var union: Int64
        var pairs: [ShareView.Pair: Int64]
    }

    static func sweep(_ lists: [[Extent]], parents: [Int?], allPairs: Bool = false) -> Sweep {
        var ev: [(pos: Int64, delta: Int32, file: Int)] = []
        ev.reserveCapacity(lists.reduce(0) { $0 + $1.count } * 2)
        for (i, l) in lists.enumerated() {
            for e in l { ev.append((e.physical, 1, i)); ev.append((e.physical + e.length, -1, i)) }
        }
        ev.sort { $0.pos < $1.pos }
        var counts = [Int32](repeating: 0, count: lists.count)
        var active = Set<Int>()
        var s = Sweep(unique: .init(repeating: 0, count: lists.count), sharedWithParent: .init(repeating: 0, count: lists.count), union: 0, pairs: [:])
        var prev: Int64 = 0
        var k = 0
        while k < ev.count {
            let pos = ev[k].pos
            let len = pos - prev
            if !active.isEmpty, len > 0 {
                s.union += len
                if active.count == 1 { s.unique[active.first!] += len }
                for i in active { if let p = parents[i], active.contains(p) { s.sharedWithParent[i] += len } }
                if allPairs, active.count > 1 {
                    let a = active.sorted()
                    for x in 0..<a.count { for y in (x + 1)..<a.count { s.pairs[ShareView.Pair(a: a[x], b: a[y]), default: 0] += len } }
                }
            }
            while k < ev.count, ev[k].pos == pos {
                let i = ev[k].file
                counts[i] += ev[k].delta
                if counts[i] > 0 { active.insert(i) } else { active.remove(i) }
                k += 1
            }
            prev = pos
        }
        return s
    }

    // MARK: ranges (byte offset, length) — sorted and disjoint unless said otherwise

    public static func total(_ r: [(Int64, Int64)]) -> Int64 { r.reduce(0) { $0 + $1.1 } }

    /// Sort and merge touching/overlapping ranges.
    public static func merge(_ r: [(Int64, Int64)]) -> [(Int64, Int64)] {
        var out: [(Int64, Int64)] = []
        for (o, l) in r.sorted(by: { $0.0 < $1.0 }) where l > 0 {
            if let last = out.last, last.0 + last.1 >= o {
                out[out.count - 1].1 = max(last.0 + last.1, o + l) - last.0
            } else { out.append((o, l)) }
        }
        return out
    }

    /// `a` ∩ `b`.
    public static func intersect(_ a: [(Int64, Int64)], _ b: [(Int64, Int64)]) -> [(Int64, Int64)] {
        var out: [(Int64, Int64)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            let s = max(a[i].0, b[j].0), e = min(a[i].0 + a[i].1, b[j].0 + b[j].1)
            if s < e { out.append((s, e - s)) }
            if a[i].0 + a[i].1 < b[j].0 + b[j].1 { i += 1 } else { j += 1 }
        }
        return out
    }

    /// `a` − `b`.
    public static func subtract(_ a: [(Int64, Int64)], _ b: [(Int64, Int64)]) -> [(Int64, Int64)] {
        var out: [(Int64, Int64)] = []
        var j = 0
        for (s0, l) in a {
            var s = s0
            let e = s0 + l
            while j < b.count, b[j].0 + b[j].1 <= s { j += 1 }
            var k = j
            while s < e {
                if k >= b.count || b[k].0 >= e { out.append((s, e - s)); break }
                if b[k].0 > s { out.append((s, b[k].0 - s)) }
                s = max(s, b[k].0 + b[k].1)
                k += 1
            }
        }
        return out.filter { $0.1 > 0 }
    }

    /// [0, size) − `r`.
    public static func complement(_ r: [(Int64, Int64)], size: Int64) -> [(Int64, Int64)] {
        subtract([(0, size)], merge(r))
    }

    /// The logical ranges where `child` maps its data differently from `parent` (a hole in the
    /// parent, or another physical block), and those where the parent has data and the child a hole.
    static func blockDelta(child: [Extent], parent: [Extent]) -> (differ: [(Int64, Int64)], holedInChild: [(Int64, Int64)]) {
        var diff: [(Int64, Int64)] = []
        func push(_ s: Int64, _ l: Int64) {
            guard l > 0 else { return }
            if let last = diff.last, last.0 + last.1 == s { diff[diff.count - 1].1 += l } else { diff.append((s, l)) }
        }
        var j = 0
        for c in child {
            var pos = c.logical
            let end = c.logical + c.length
            while j < parent.count, parent[j].logical + parent[j].length <= pos { j += 1 }
            var k = j
            while pos < end {
                if k >= parent.count || parent[k].logical >= end { push(pos, end - pos); break }
                let p = parent[k]
                if p.logical > pos { let stop = min(p.logical, end); push(pos, stop - pos); pos = stop; continue }
                let stop = min(p.logical + p.length, end)
                if c.physical + (pos - c.logical) != p.physical + (pos - p.logical) { push(pos, stop - pos) }
                pos = stop
                if stop == p.logical + p.length { k += 1 }
            }
        }
        let holed = subtract(merge(parent.map { ($0.logical, $0.length) }), merge(child.map { ($0.logical, $0.length) }))
        return (diff, holed)
    }

    /// The 4 KiB-block runs within `ranges` whose content in `child` differs from `parent` (past
    /// the parent's end reads as zeros), and the bytes compared that were identical.
    static func contentRuns(child: URL, parent: URL, ranges: [(Int64, Int64)]) throws -> (runs: [(Int64, Int64)], identical: Int64) {
        let cf = open(child.path, O_RDONLY), pf = open(parent.path, O_RDONLY)
        defer { if cf >= 0 { close(cf) }; if pf >= 0 { close(pf) } }
        guard cf >= 0, pf >= 0 else { throw EXT4Inspector.InspectError.unreadable("\(child.path) / \(parent.path)") }
        var out: [(Int64, Int64)] = []
        var same: Int64 = 0
        let chunk = 8 << 20
        var cb = [UInt8](repeating: 0, count: chunk), pb = [UInt8](repeating: 0, count: chunk)
        for (o0, l) in ranges {
            var o = o0
            while o < o0 + l {
                let k = Int(min(Int64(chunk), o0 + l - o))
                let cr = cb.withUnsafeMutableBytes { pread(cf, $0.baseAddress!, k, off_t(o)) }
                guard cr >= 0 else { throw EXT4Inspector.InspectError.unreadable(child.path) }
                if cr < k { for z in max(cr, 0)..<k { cb[z] = 0 } }
                let pr = pb.withUnsafeMutableBytes { pread(pf, $0.baseAddress!, k, off_t(o)) }
                if pr < k { for z in max(pr, 0)..<k { pb[z] = 0 } }
                var b = 0
                while b < k {
                    let m = min(4096, k - b)
                    let differs = cb.withUnsafeBytes { c in pb.withUnsafeBytes { p in memcmp(c.baseAddress! + b, p.baseAddress! + b, m) != 0 } }
                    if differs {
                        let at = o + Int64(b)
                        if let last = out.last, last.0 + last.1 == at { out[out.count - 1].1 += Int64(m) } else { out.append((at, Int64(m))) }
                    } else { same += Int64(m) }
                    b += m
                }
                o += Int64(k)
            }
        }
        return (out, same)
    }

    /// Write `ranges` of `src` into `dst` at the same offsets. Returns the bytes written.
    static func copyRanges(_ src: URL, _ dst: URL, _ ranges: [(Int64, Int64)]) throws -> Int64 {
        let sf = open(src.path, O_RDONLY), df = open(dst.path, O_RDWR)
        defer { if sf >= 0 { close(sf) }; if df >= 0 { close(df) } }
        guard sf >= 0, df >= 0 else { throw EXT4Inspector.InspectError.unreadable("\(src.path) → \(dst.path)") }
        var buf = [UInt8](repeating: 0, count: 8 << 20)
        var n: Int64 = 0
        for (o0, l) in ranges {
            var o = o0
            while o < o0 + l {
                let k = Int(min(Int64(buf.count), o0 + l - o))
                let r = buf.withUnsafeMutableBytes { pread(sf, $0.baseAddress!, k, off_t(o)) }
                guard r >= 0 else { throw EXT4Inspector.InspectError.unreadable(src.path) }
                if r < k { for z in max(r, 0)..<k { buf[z] = 0 } }
                guard buf.withUnsafeBytes({ pwrite(df, $0.baseAddress!, k, off_t(o)) }) == k else {
                    throw EXT4Inspector.InspectError.unreadable("write \(dst.path) at \(o): \(String(cString: strerror(errno)))")
                }
                n += Int64(k); o += Int64(k)
            }
        }
        guard fsync(df) == 0 else { throw EXT4Inspector.InspectError.unreadable("fsync \(dst.path)") }
        return n
    }

    /// Punch holes (`F_PUNCHHOLE`) in `url` over `ranges` (block-aligned). Returns the number of calls.
    @discardableResult
    public static func punchHoles(_ url: URL, _ ranges: [(Int64, Int64)]) throws -> Int {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw EXT4Inspector.InspectError.unreadable(url.path) }
        defer { close(fd) }
        var n = 0
        // struct fpunchhole { u32 fp_flags; u32 reserved; off_t fp_offset; off_t fp_length }
        var buf = [UInt8](repeating: 0, count: 24)
        for (o, l) in ranges where l > 0 {
            buf.withUnsafeMutableBytes { p in
                p.storeBytes(of: UInt32(0), toByteOffset: 0, as: UInt32.self)
                p.storeBytes(of: UInt32(0), toByteOffset: 4, as: UInt32.self)
                p.storeBytes(of: o, toByteOffset: 8, as: Int64.self)
                p.storeBytes(of: l, toByteOffset: 16, as: Int64.self)
            }
            guard buf.withUnsafeMutableBytes({ fcntl(fd, F_PUNCHHOLE, $0.baseAddress!) }) == 0 else {
                throw EXT4Inspector.InspectError.unreadable("\(url.path): F_PUNCHHOLE at \(o)+\(l): \(String(cString: strerror(errno)))")
            }
            n += 1
        }
        guard fsync(fd) == 0 else { throw EXT4Inspector.InspectError.unreadable("fsync \(url.path)") }
        return n
    }

    /// True when `a` and `b` read the same over `ranges` (holes and past-the-end read as zeros).
    public static func identical(_ a: URL, _ b: URL, over ranges: [(Int64, Int64)]) throws -> Bool {
        try contentRuns(child: a, parent: b, ranges: ranges).runs.isEmpty
    }
}
