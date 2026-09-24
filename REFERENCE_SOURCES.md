
# 36. Reference repositories

Перед реализацией соответствующего subsystem обязательно изучить существующие open-source реализации ниже.

Цель — не изобретать заново уже решённые transport/SketchUp/MCP-задачи.

При этом:

1. Не копировать архитектуру репозитория целиком.
2. Не импортировать чужой код без проверки лицензии.
3. Фиксировать commit SHA, который был изучен.
4. Если код адаптирован непосредственно, сохранить attribution и выполнить требования лицензии.
5. Предпочитать небольшие адаптированные реализации вместо добавления зависимости на целый проект.
6. Сначала понять, почему исходный проект реализован именно так.
7. Исправлять известные недостатки исходного проекта при переносе.

---

## 36.1 Primary reference — zinin/sketchup-mcp2

Repository:

https://github.com/zinin/sketchup-mcp2

Primary reference для инфраструктуры HomeCAD.

Изучить в первую очередь:

```text
src/sketchup_mcp/
mcp_for_sketchup/
tests/
test/
examples/
docs/
```

Использовать как reference для:

```text
Python MCP server
↕
TCP JSON-RPC
↕
SketchUp Ruby extension
```

Особенно изучить:

```text
connection management
JSON-RPC framing
persistent connection
version handshake
multi-client handling
SketchUp UI-thread dispatch
timeouts
reconnect
structured errors
```

Также использовать как reference для:

```text
get_viewport_screenshot
undo
get_model_info
get_component_info
find_components
layers
materials
export
eval_ruby gate
RBZ packaging
logging
settings dialog
```

Особенно важны идеи:

```text
public dimensions in mm
bbox_mm
atomic SketchUp operations
viewport screenshot returned to MCP
version compatibility between Python and Ruby halves
```

Не копировать domain model.

HomeCAD architecture / furniture / electrical / lighting должны быть нашими.

License at time of review:

```text
MIT
```

Если непосредственно используется существенный код, сохранить необходимые copyright/license notices.

---

# 36.2 Architecture reference — SidhNor/sketchup-mcp-server

Repository:

https://github.com/SidhNor/sketchup-mcp-server

Использовать в первую очередь как **architectural reference**, а не как code donor.

Изучить идеи:

```text
TargetReferenceResolver

home/persistent/entity identity resolution

ambiguous target detection

find_entities

measure_scene

validate_scene_update

structured mutation results

read-only/destructive tool classification

central transaction wrapper

post-mutation verification
```

Особенно перенять концепцию:

```text
none
unique
ambiguous
```

При ambiguous target HomeCAD не должен сам выбирать объект.

Также изучить pattern:

```text
start_operation
→ execute
→ commit_operation

exception
→ abort_operation
```

License:

```text
MIT
```

# 36.3 Primitive geometry reference — Tarkiin/SketchUp-MCP

Repository:

https://github.com/Tarkiin/SketchUp-MCP

Использовать как reference для низкоуровневой geometry API.

Особенно изучить:

```text
create_face
create_edge
create_group
create_box

create_circle
create_arc
create_polygon

push_pull
follow_me

move_entity
rotate_entity
scale_entity

create_component
place_component
```

Эти tools могут стать основой HomeCAD `developer/geometry` fallback layer.

Не переносить публичную unit semantics без проверки.

В исходном проекте есть риск путаницы между обычными numeric SketchUp Length и model units.

HomeCAD должен использовать:

```text
MCP API = millimeters
Ruby conversion = centralized
```

Нельзя позволять raw numeric coordinate напрямую интерпретировать как SketchUp internal inches.

Также заменить:

```text
entityID-only targeting
```

на:

```text
homecad_id
persistent_id
entity_id
```

License:

```text
MIT
```

---

# 36.4 Agentic workflow reference — darwin/supex

Repository:

https://github.com/darwin/supex

Использовать как reference для agent-oriented SketchUp workflow.

Особенно изучить:

```text
get_entity
get_model_info
get_selection
get_layers
get_materials
get_camera_info

take_screenshot
take_batch_screenshots

open_model
save_model
export_scene

eval_ruby
eval_ruby_file
```

Изучить подход:

```text
agent writes
→ executes
→ inspects
→ screenshots
→ verifies
→ iterates
```

Полезные идеи:

```text
project-centric workflow
git-versioned scripts
agent documentation
screenshot verification
Ruby stdlib helpers
with_operation helper
```

VCAD/BRep subsystem изучить как возможное направление после HomeCAD 1.0.

Не включать VCAD в MVP.

HomeCAD MVP не требует:

```text
Rust sidecar
BRep engine
Loon
Tauri viewer
```

License:

```text
MIT
```

Обращать внимание на attribution внутри Supex: некоторые utility-файлы сами адаптированы из других MIT-проектов.

При переносе такого кода необходимо сохранять цепочку attribution.

---

# 36.5 Security reference — NeoNexAI/sketchup-mcp

Repository:

https://github.com/NeoNexAI/sketchup-mcp

Использовать для изучения минимального bounded MCP surface.

Особенно посмотреть:

```text
localhost-only transport
input validation
explicit tool schemas
retry behavior
actionable connection errors
removal of arbitrary eval
security documentation
```

Этот проект полезен как противоположность unrestricted `eval_ruby`.

В HomeCAD сделать гибрид:

```text
normal tools
    ↓
safe typed operations

eval_ruby
    ↓
disabled by default
explicitly enabled
escape hatch only
```

License:

```text
MIT
```

---

# 36.6 Minimal bridge reference — Shattenjagger/sketchup-mcp-bridge

Repository:

https://github.com/Shattenjagger/sketchup-mcp-bridge

Использовать как небольшой reference implementation bridge.

Особенно изучить:

```text
Ruby bridge
scene info
selection
screenshot
MCP image response
SketchUp 2026 behavior
```

Этот проект полезен для сравнения с более сложным `sketchup-mcp2`.

Если одну задачу можно реализовать проще и надёжнее, предпочитать простой вариант.

License:

```text
MIT
```

---

# 36.7 Legacy / woodworking reference — mhyrr/sketchup-mcp

Repository:

https://github.com/mhyrr/sketchup-mcp

Не использовать как основную архитектуру.

Использовать только как reference для отдельных geometry operations:

```text
boolean_operation
chamfer_edges
fillet_edges

create_mortise_tenon
create_dovetail
create_finger_joint
```

Это особенно интересно для будущего Furniture module.

Проверять каждый implementation отдельно:

некоторые возможности Ruby bridge исторически не были синхронизированы с Python MCP surface.

Не считать README источником истины без проверки реализации.

License:

```text
MIT
```

---

# 36.8 Official SketchUp Ruby API

Primary API documentation:

https://ruby.sketchup.com/

Это главный источник истины по поведению SketchUp.

При расхождении reference repository и официального API доверять официальному API.

Особенно изучать:

```text
Sketchup::Model
Sketchup::Entities
Sketchup::Entity
Sketchup::Group
Sketchup::ComponentInstance
Sketchup::ComponentDefinition

Sketchup::Face
Sketchup::Edge

Geom::Point3d
Geom::Vector3d
Geom::Transformation

Sketchup::AttributeDictionary

Sketchup::View
Sketchup::Camera
```

Обязательно проверять:

```text
Length semantics
persistent_id
entityID
start_operation
commit_operation
abort_operation
valid?
deleted?
transformations
active_entities
model.entities
```

---

# 36.9 Reference priority by subsystem

Для Transport:

```text
1. zinin/sketchup-mcp2
2. Shattenjagger/sketchup-mcp-bridge
3. Supex
```

Для Targeting:

```text
1. SidhNor — architecture ideas only
2. official SketchUp API
3. zinin
```

Для Transactions:

```text
1. official SketchUp API
2. SidhNor — pattern/reference
3. zinin
4. Supex
```

Для Screenshot:

```text
1. zinin/sketchup-mcp2
2. Supex
3. Shattenjagger
```

Для Primitive geometry:

```text
1. Tarkiin
2. official SketchUp API
3. mhyrr
```

Для Booleans / fillet / chamfer:

```text
1. mhyrr
2. NeoNexAI fork
3. Supex / VCAD for future research
```

Для Furniture:

```text
1. HomeCAD original implementation
2. mhyrr only for woodworking geometry ideas
```

Для Architecture / Apartment:

```text
HomeCAD original implementation
```

Для Kitchen:

```text
HomeCAD original implementation
```

Для Electrical:

```text
HomeCAD original implementation
```

Для Lighting:

```text
HomeCAD original implementation
```

---

# 36.10 Reference inspection workflow

Перед реализацией subsystem Codex должен:

```text
1. Найти соответствующий subsystem в reference repositories.
2. Записать repository + commit SHA.
3. Найти относящиеся к задаче source files.
4. Прочитать tests вместе с implementation.
5. Проверить официальный SketchUp Ruby API.
6. Записать найденные хорошие решения.
7. Записать найденные недостатки.
8. Спроектировать HomeCAD API.
9. Только после этого писать код.
```

Для каждого milestone добавить в PR/commit notes:

```text
References reviewed:
- repository:
- commit:
- files:
- ideas reused:
- intentionally not reused:
- license implications:
```

---

# 36.11 Do not blindly copy

В частности:

### Не переносить из Tarkiin

```text
неявные SketchUp units
entityID-only architecture
```

### Не переносить из mhyrr

```text
несинхронизированные Python/Ruby tool surfaces
```

### Не переносить из SidhNor

```text
исходный код без соблюдения AGPL
site/terrain-specific domain model
```

### Не переносить из Supex в MVP

```text
VCAD
Rust sidecar
Tauri viewer
сложность, не нужную квартире
```

### Не переносить из zinin буквально

```text
component-centric domain model
woodworking-centric tools
```

HomeCAD должен оставаться специализированным для:

```text
Apartment
Architecture
Furniture
Kitchen
Electrical
Lighting
```

---

# 36.12 Local reference checkout

Для серьёзной реализации разрешается клонировать reference repositories во временную директорию:

```text
.references/
```

Добавить её в `.gitignore`.

Пример:

```text
.references/
├── sketchup-mcp2/
├── tarkiin-sketchup-mcp/
├── sidhNor-sketchup-mcp-server/
├── supex/
├── neonex-sketchup-mcp/
├── sketchup-mcp-bridge/
└── mhyrr-sketchup-mcp/
```

Reference repositories никогда не должны автоматически становиться частью HomeCAD source tree.

Не делать copy-all.

Изучать конкретные implementation/tests и переносить только необходимое.

---

# 36.13 Core rule

Главная стратегия HomeCAD:

```text
zinin
    ↓
transport + screenshot + operational robustness

SidhNor
    ↓
targeting + validation concepts

Tarkiin
    ↓
primitive geometry

Supex
    ↓
agent workflow concepts

NeoNex
    ↓
security concepts

mhyrr
    ↓
specialized furniture geometry

official SketchUp Ruby API
    ↓
source of truth

                +
                ↓

our own domain model

Apartment
Furniture
Kitchen
Electrical
Lighting
```

HomeCAD не должен быть форком одного из этих проектов.

Он должен быть новым domain-oriented MCP system, использующим проверенные решения нескольких существующих implementations.