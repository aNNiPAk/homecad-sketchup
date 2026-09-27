# M5.5 decisions

- An L-shaped kitchen is one `kitchen.run` root with two Wall legs, not a second hierarchy
  of linked one-Wall runs. Legacy parameter JSON and public tools remain accepted.
- Two generic Wall IDs are indexed on the root separately from the single-host
  `WallAttachment` projection. Architecture preflights the full corner geometry before
  its operation and regenerates the Kitchen child geometry inside that operation.
- The first corner is orthogonal, endpoint-connected, counterclockwise, and base-tier only.
  These restrictions make interior side, occupied volume, and Wall-driven regeneration
  deterministic. A change to one Wall that breaks the connection is rejected atomically.
- The void corner consists of two closing front panels. The blind cabinet is a simple
  rectangular case with access on a selected leg; its cutlist is preliminary and warns
  that the join needs manufacturing review.
- M5.2 service zones are checked against the opposite leg and corner in world space.
  The KitchenRun root and semantic child UUIDs remain stable across valid updates.
- Continuous corner countertops and panel/edge finish variants are reserved for M5.6.
