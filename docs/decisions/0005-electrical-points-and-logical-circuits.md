# ADR 0005: Electrical points and logical circuits

Status: accepted for implementation; milestone acceptance requires packaged smoke.

Electrical points are generated root Groups with stable identity and explicit local
dimensions. Canonical placement is a Wall center in U/Z or a world rear-plane center
with normal/up axes. WallAttachment stores a derived corner/span projection only.

Circuit has no geometric location and is stored as a UUID record in model metadata.
Its null SketchUp identity fields and dedicated get/list APIs distinguish it from
entities. Targeting resolves logical records by exact UUID. Membership is owned by
the point, preventing an independently editable second list in Circuit.

DomainHooks executes callbacks before Operation.commit_operation. It maintains
membership revisions after cascade deletion without nesting an operation. The
Architecture serializer preserves each dependent domain's tombstone parameters.
Callbacks can fail and roll back the same native SketchUp operation.

Electrical support is read from occupied Wall cells on the selected side. Direct
create/update requires support; later Architecture cuts may remove it with an
advisory warning. Wall fit remains a blocking invariant. Geometry collision checks
use canonical HomeCAD volumes and 3D OBB SAT, enabling floor/ceiling placement.

All sizes, labels and voltage are explicit project values. These concept objects
do not imply correct wiring, protection, drilling or regulatory compliance. M6.1
will address routes/panels/consumers separately.
