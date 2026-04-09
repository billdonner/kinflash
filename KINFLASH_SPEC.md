# KinFlash — Full Application Spec

## Claude Code Handoff Document

---

## 1. Overview

**KinFlash** is an iOS/macOS app (via Mac Catalyst) for building, managing, and exploring family trees. It combines AI-powered conversational onboarding, a visual interactive family tree, a personal archive of photos and documents per person, and an AI-generated flashcard system for learning family relationships.

The app is designed as a personal/family tool. It is privacy-first, with all data stored on device. AI features default to Apple Intelligence (on-device, free, no setup) with optional fallback to user-supplied Anthropic or OpenAI API keys.

## 2. Platform Targets

| Platform | Mechanism | Notes |
|----------|-----------|-------|
| iPhone | Native SwiftUI | Primary design target |
| iPad | SwiftUI adaptive | Sidebar + detail layout |
| Mac | Mac Catalyst | Via iPad build, no separate codebase |

- Minimum iOS: **26.0**
- Xcode: **26+**
- Swift: **6.0**
- No third-party SPM dependencies except **GRDB** (SQLite wrapper — the one acknowledged dependency)
- Native frameworks: SwiftUI, PDFKit, QuickLook, Foundation Models, StoreKit 2, VisionKit

## 3. Architecture

### 3.1 Layered Structure

```
┌─────────────────────────────────────┐
│          SwiftUI Views              │
├─────────────────────────────────────┤
│     @Observable ViewModels          │
├─────────────────────────────────────┤
│         Domain Services             │
│  TreeService  │  FlashcardService   │
│  InterviewService │ GEDCOMService   │
├─────────────────────────────────────┤
│        AI Provider Layer            │
│  AIProvider protocol                │
│  AppleIntelligenceProvider          │
│  AnthropicProvider                  │
│  OpenAIProvider                     │
├─────────────────────────────────────┤
│        Persistence Layer            │
│  GRDB (SQLite)  │  FileManager      │
└─────────────────────────────────────┘
```

All ViewModels use `@Observable` (not `ObservableObject`). iOS 26+ minimum means Observation framework is always available.

No `AppDelegate` — pure `@main App` struct entry point.

### 3.2 AI Provider Protocol

All AI features route through a single protocol so views and services never care which provider is active:

```swift
protocol AIProvider {
    func chat(messages: [AIMessage]) async throws -> String
    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error>
    func structured<T: Decodable & Sendable>(
        prompt: String,
        schema: AISchema,
        as type: T.Type
    ) async throws -> T
    var isAvailable: Bool { get }
}

struct AIMessage: Sendable {
    let role: AIRole  // .system, .user, .assistant
    let content: String
}

/// Describes the expected JSON shape for cloud providers,
/// ignored by AppleIntelligenceProvider (which uses @Generable at compile time)
struct AISchema: Sendable {
    let description: String
    let jsonSchema: String  // JSON Schema string for Anthropic/OpenAI
}
```

**Streaming:** `chatStream()` is required for the interview UI — users must see tokens arrive incrementally. `chat()` is a convenience that collects the full stream.

**Structured output divergence:** Apple Intelligence uses `@Generable` (compile-time conformance). Anthropic/OpenAI use JSON mode with a schema in the system prompt. The `structured()` method on `AppleIntelligenceProvider` requires `T` to also conform to the `@Generable` protocol. Types used with structured output must conform to both `Decodable` and `@Generable`. This is enforced by making shared structured-output types (e.g., `GeneratedFlashcard`, `ExtractedPerson`) conform to both protocols.

**Cancellation:** All async methods must respect Swift structured concurrency cancellation. Implementations should check `Task.isCancelled` and throw `CancellationError` promptly.

**Retry/rate-limit:** Cloud providers (Anthropic, OpenAI) implement automatic retry with exponential backoff for 429 (rate limit) and 5xx errors, up to 3 retries. Surface a user-visible error after retries are exhausted.

**Concrete implementations:**

- `AppleIntelligenceProvider` — uses `FoundationModels` framework, `@Generable` for structured output
- `AnthropicProvider` — `URLSession` calls to `api.anthropic.com/v1/messages`, JSON mode for structured output
- `OpenAIProvider` — `URLSession` calls to `api.openai.com/v1/chat/completions`, JSON mode for structured output

**Provider selection logic (`AIProviderRouter`):**

1. If user has selected Anthropic + valid key → use Anthropic
2. Else if user has selected OpenAI + valid key → use OpenAI
3. Else if device supports Apple Intelligence → use Apple Intelligence
4. Else → prompt user to configure a provider in Settings

### 3.3 Storage

**GRDB (SQLite)** for all structured data. Single database file in app's Documents directory. Foreign key enforcement enabled (`PRAGMA foreign_keys = ON`).

**FileManager** for binary attachments (photos, documents). Stored under:
```
/Documents/kinflash/people/{person-uuid}/photos/
/Documents/kinflash/people/{person-uuid}/documents/
```

**Keychain** for all API keys. Never stored in UserDefaults or database.

### 3.4 Error Handling Strategy

Every user-facing operation must handle errors gracefully:

| Scenario | Behavior |
|----------|----------|
| AI provider call fails (network) | Show inline error banner with "Retry" button |
| AI provider call fails (auth/key) | Redirect to Settings with explanation |
| AI provider rate-limited (429) | Auto-retry with backoff up to 3 times, then show error |
| GEDCOM parse error | Show error summary with line numbers; import valid records, skip invalid |
| Database corruption | Show alert, offer "Export raw data" before reset |
| Attachment file missing | Show placeholder with "File not found" label |

---

## 4. Data Model

### 4.1 GRDB Schema

```swift
// AppSettings — singleton row for app-wide config
struct AppSettings: Codable, FetchableRecord, PersistableRecord {
    var id: Int = 1                  // always 1, singleton
    var rootPersonId: UUID?          // the "me" person — perspective root
    var hasCompletedOnboarding: Bool
    var selectedAIProvider: String?  // "apple", "anthropic", "openai"
    var selectedModel: String?       // e.g. "claude-sonnet-4-6"
    var createdAt: Date
    var updatedAt: Date
}

// Person
struct Person: Codable, FetchableRecord, PersistableRecord {
    var id: UUID
    var firstName: String
    var middleName: String?
    var lastName: String?
    var nickname: String?
    var birthDate: Date?
    var birthYear: Int?              // when full date unknown
    var deathDate: Date?
    var deathYear: Int?
    var isLiving: Bool               // true = alive, false = deceased (separate from deathDate being nil)
    var birthPlace: String?
    var gender: Gender?              // .male, .female, .nonBinary, .unknown
    var notes: String?
    var profilePhotoFilename: String?
    var gedcomId: String?            // original GEDCOM @Ixx@ ID if imported
    var createdAt: Date
    var updatedAt: Date
}

// Relationship
// STORAGE RULE: one row per directed edge.
//   .parent  → one row: fromPersonId is parent OF toPersonId
//   .spouse  → TWO rows: A→B and B→A (bidirectional)
//   .sibling → TWO rows: A→B and B→A (bidirectional)
struct Relationship: Codable, FetchableRecord, PersistableRecord {
    var id: UUID
    var fromPersonId: UUID           // FK → Person.id, ON DELETE CASCADE
    var toPersonId: UUID             // FK → Person.id, ON DELETE CASCADE
    var type: RelationshipType       // .parent, .spouse, .sibling
    var subtype: RelationshipSubtype? // .biological, .step, .adoptive, .half (for parent/sibling)
    var startDate: Date?             // marriage date for spouses
    var endDate: Date?               // divorce/death
    var createdAt: Date
}

// Attachment
struct Attachment: Codable, FetchableRecord, PersistableRecord {
    var id: UUID
    var personId: UUID               // FK → Person.id, ON DELETE CASCADE
    var type: AttachmentType         // .photo, .document
    var filename: String
    var label: String?               // "Birth Certificate", "Wedding Photo"
    var createdAt: Date
    var updatedAt: Date
}

// FlashcardDeck
struct FlashcardDeck: Codable, FetchableRecord, PersistableRecord {
    var id: UUID
    var perspectivePersonId: UUID    // FK → Person.id, ON DELETE CASCADE
    var generatedAt: Date
    var cardCount: Int
}

// Flashcard
struct Flashcard: Codable, FetchableRecord, PersistableRecord {
    var id: UUID
    var deckId: UUID                 // FK → FlashcardDeck.id, ON DELETE CASCADE
    var question: String             // "Who is your father's sister?"
    var answer: String               // "Aunt Carol"
    var explanation: String?         // additional context
    var chain: String?               // "father → sister" for debugging
    var status: FlashcardStatus      // .unknown, .learning, .known
    var lastReviewedAt: Date?
}

enum FlashcardStatus: String, Codable {
    case unknown
    case learning
    case known
}

enum RelationshipSubtype: String, Codable {
    case biological
    case step
    case adoptive
    case half    // half-sibling
}
```

### 4.2 Foreign Key & Cascade Rules

All foreign keys use `ON DELETE CASCADE`:
- Deleting a `Person` cascades to: their `Relationship` rows, `Attachment` rows, `FlashcardDeck` rows (which cascade to `Flashcard` rows)
- Deleting a `FlashcardDeck` cascades to its `Flashcard` rows
- Attachment files on disk are cleaned up by `AttachmentManager` via a GRDB `didDelete` hook

### 4.3 Data Validation Rules

| Rule | Enforcement |
|------|-------------|
| No circular parent chains (A parent of B, B parent of A) | `TreeService.addRelationship()` runs cycle detection before insert |
| No self-relationships | Check `fromPersonId != toPersonId` before insert |
| No duplicate relationships | Unique constraint on `(fromPersonId, toPersonId, type)` |
| Birth date before death date | Validated in `Person` setter / form validation |
| `birthYear` ignored if `birthDate` is set | `birthYear` is a fallback only — UI derives display from `birthDate` first |

### 4.4 Relationship Types

Only three primitive relationship types are stored. All colloquial labels (uncle, cousin, grandmother, etc.) are computed by traversal:

- `.parent` — fromPerson is parent of toPerson (directed)
- `.spouse` — bidirectional partnership (stored as two rows)
- `.sibling` — derived from shared parents OR stored explicitly for half-siblings / imported trees (stored as two rows)

### 4.5 Colloquial Relationship Computation

`RelationshipResolver` takes two person IDs and returns a colloquial label via BFS traversal up to **4 hops** (increased from 3 to cover in-laws and second cousins):

| Hops | Example path | Label |
|------|-------------|-------|
| 1 | parent | Father / Mother |
| 1 | spouse | Husband / Wife |
| 2 | parent → sibling | Uncle / Aunt |
| 2 | parent → parent | Grandfather / Grandmother |
| 2 | sibling → child | Nephew / Niece |
| 2 | spouse → parent | Father-in-law / Mother-in-law |
| 3 | parent → sibling → child | First Cousin |
| 3 | parent → parent → sibling | Great Uncle / Great Aunt |
| 3 | parent → parent → parent | Great Grandfather / Great Grandmother |
| 3 | sibling → spouse | Brother-in-law / Sister-in-law (sibling's spouse) |
| 3 | spouse → sibling | Brother-in-law / Sister-in-law (spouse's sibling) |
| 4 | parent → parent → sibling → child | First Cousin Once Removed |
| 4 | parent → sibling → child → child | First Cousin's Child |

**Gender-neutral fallbacks:** When gender is `.nonBinary` or `.unknown`, use descriptive labels:
- "Parent" instead of Father/Mother
- "Spouse/Partner" instead of Husband/Wife
- "Parent's Sibling" instead of Uncle/Aunt
- "Sibling's Child" instead of Nephew/Niece
- "Grandparent" instead of Grandfather/Grandmother

**Step/adoptive prefix:** When traversal crosses a relationship with `subtype: .step`, prepend "Step-" to the label (e.g., "Stepfather"). Same for `.adoptive` → "Adoptive".

Unresolved relationships beyond 4 hops → "Distant Relative"

---

## 5. Screens & Navigation

### 5.1 App Entry / Onboarding

Shown on first launch only (`AppSettings.hasCompletedOnboarding == false`):

1. **Welcome screen** — app name, brief description
2. **AI Setup screen** — detects Apple Intelligence support
   - If supported: "You're all set — KinFlash uses on-device AI" → continue
   - If not supported: prompt to configure provider in Settings, or skip for now (tree building without AI works, interview requires AI)
3. **Privacy consent screen** — if user selects a cloud AI provider, explain that names and relationships will be sent to Anthropic/OpenAI. Require explicit consent toggle before proceeding.
4. **Start screen** — two options:
   - "Build my tree" → Interview flow
   - "Import a .ged file" → Document picker

### 5.2 Main Navigation

`NavigationSplitView` with three columns (collapses appropriately on iPhone):

```
Sidebar           | Content            | Detail
──────────────────|────────────────────|──────────────
My Tree           | Visual Tree        | Person Profile
People (list)     |                    |
Flashcard Decks   |                    |
Interview         |                    |
Settings          |                    |
```

### 5.3 Visual Tree View

The central feature of the app. A zoomable, pannable canvas showing the family tree.

**Layout:**

- Generational rows — each generation on a horizontal band
- Persons rendered as cards (see below)
- Horizontal line connecting spouses
- Vertical + horizontal lines connecting parents to children
- Root person (the app owner / perspective person) highlighted with accent border
- "Fit All" button in toolbar to zoom-to-fit the entire tree
- Search bar: type a name → tree animates to center on that person

**Person card (tree node):**
```
┌──────────────┐
│      ◉       │  ← circular profile photo (placeholder if none)
│  John Smith  │
│ 1945 — 2018  │
└──────────────┘
```

**Gestures:**

- Pinch → zoom in/out
- Drag → pan
- Tap → open Person Profile sheet
- Long press → context menu (see below)

**Long press context menu:**
```
◉ John Smith
──────────────────
 👤 View Profile
 ✨ Generate Flashcards
 📷 Add Photo
 ✏️ Edit Person
 🔗 Add Relationship
 🗑️ Remove from Tree (confirmation required)
```

**Technical approach:**

- SwiftUI `Canvas` for drawing connection lines
- `ScrollView` with `.pinchToZoom` gesture for navigation
- Person cards as SwiftUI views positioned absolutely via `offset`
- Layout algorithm: modified Sugiyama algorithm (layered graph drawing):
  1. Assign each person to a generation layer via BFS from root
  2. Order nodes within each layer to minimize edge crossings
  3. Assign x-coordinates with minimum spacing, centering parents over children
  4. Handle multiple marriages: spouse pairs placed adjacent, children centered below the pair
  5. Handle disconnected subtrees: render as separate clusters with spacing
  6. Handle pedigree collapse (shared ancestors): node appears once in its earliest generation, edges fan out

**Performance:** For trees exceeding ~100 visible nodes, render only nodes within the visible viewport + a buffer zone. Off-screen nodes are removed from the view hierarchy and re-added on scroll.

### 5.4 Person Profile Sheet

Full-screen sheet or navigation push:

```
┌─────────────────────────────────────┐
│  ◉  John Robert Smith              │
│      "Johnny"                       │
│      Born: June 12, 1945 · Chicago  │
│      Died: March 3, 2018            │
├─────────────────────────────────────┤
│  RELATIONSHIPS                      │
│  Spouse    → Mary Smith             │
│  Father   → Robert Smith Sr.        │
│  Mother   → Helen Smith             │
│  Son      → Michael Smith           │
│  Son      → David Smith             │
│  Daughter → Carol Jones             │
├─────────────────────────────────────┤
│  PHOTOS                    [+ Add]  │
│  ┌───┐ ┌───┐ ┌───┐                 │
│  │   │ │   │ │   │  →              │
│  └───┘ └───┘ └───┘                 │
├─────────────────────────────────────┤
│  DOCUMENTS                 [+ Add]  │
│  📄 Birth Certificate               │
│  📄 Military Service Record          │
│  📄 Obituary                         │
├─────────────────────────────────────┤
│  NOTES                     [Edit]   │
│  Served in Vietnam 1966–1968.       │
│  Retired from Ford Motor Co. 1987.  │
└─────────────────────────────────────┘
```

**Photo viewer:**
- Tap photo → full screen with swipe between photos
- Long press → "Set as Profile Photo" / "Delete"
- Sources: Photo Library, Camera, Files

**Document viewer:**
- Tap → QuickLook preview (handles PDF, images, etc. natively)
- Long press → "Rename" / "Delete"
- Sources: Files app, Scanner (VisionKit document scanner)

### 5.5 Interview Screen

Chat-style interface. Used for initial tree building or adding new people later.

```
┌─────────────────────────────────────┐
│  ← Back          Interview          │
├─────────────────────────────────────┤
│                                     │
│  ┌──────────────────────────────┐   │
│  │ Hi! I'm going to help you   │   │
│  │ build your family tree. Let's│   │
│  │ start with you. What's your  │   │
│  │ full name?                   │   │
│  └──────────────────────────────┘   │
│                                     │
│       ┌──────────────────────┐      │
│       │ John Robert Smith    │      │
│       └──────────────────────┘      │
│                                     │
│  ┌──────────────────────────────┐   │
│  │ Great! And when were you     │   │  ← tokens stream in
│  │ born, John?                  │   │
│  └──────────────────────────────┘   │
│                                     │
├─────────────────────────────────────┤
│  [Type a message...]      [Send ↑]  │
└─────────────────────────────────────┘
```

**AI responses stream token-by-token** via `chatStream()` so the user sees text appear incrementally.

**Interview logic (handled by AI via structured output):**

The AI extracts structured `ExtractedPerson` objects from conversation and signals when a person is complete. The interview covers:

- Name (first, middle, last, nickname)
- Birth year / date / place
- Death year / date (if applicable)
- Whether person is living
- Gender
- Key relationships (parents, spouse, children, siblings)

After each person, AI asks: "Would you like to add another family member, or are you done for now?"

**Structured extraction type (shared between all providers):**

```swift
@Generable  // for Apple Intelligence
struct ExtractedPerson: Codable, Sendable {
    let firstName: String
    let middleName: String?
    let lastName: String?
    let nickname: String?
    let birthYear: Int?
    let birthPlace: String?
    let isLiving: Bool
    let deathYear: Int?
    let gender: String?            // "male", "female", "nonBinary", "unknown"
    let relationships: [ExtractedRelationship]
    let isComplete: Bool           // AI signals when it has enough info
}

@Generable
struct ExtractedRelationship: Codable, Sendable {
    let type: String               // "parent", "spouse", "sibling", "child"
    let personName: String         // name reference to link later
}
```

**Structured extraction prompt strategy:**

- System prompt explains the goal and desired output format
- Each user turn is processed to extract any new person data
- Extracted persons are immediately written to GRDB and appear in the tree
- Duplicate detection: if extracted name matches an existing person (fuzzy match on first+last), prompt user to confirm "Is this the same person as [existing]?"

### 5.6 Flashcard Generation Sheet

Triggered from long press → "Generate Flashcards" on any person node:

```
┌─────────────────────────────────────┐
│      Generate Flashcards            │
│      for Mary Smith                 │
├─────────────────────────────────────┤
│  From Mary's perspective, we'll     │
│  generate questions about her       │
│  family relationships.              │
│                                     │
│  Tree coverage: 24 people           │
│  Estimated cards: ~18               │
│                                     │
│         [ Generate ✨ ]             │
├─────────────────────────────────────┤
│  ▓▓▓▓▓▓▓▓░░░░░░░░  8 of 18        │
│  Generating...                      │
└─────────────────────────────────────┘
```

After generation → deck preview screen → Study or Export PDF options.

### 5.7 Study Mode

Flip-card interface:

```
┌─────────────────────────────────────┐
│ Mary's Deck          Card 4 of 18   │
│ ████████░░░░░░░░░░░░                │
├─────────────────────────────────────┤
│                                     │
│                                     │
│       Who is your father's          │
│            sister?                  │
│                                     │
│                                     │
│          [ Tap to flip ]            │
├─────────────────────────────────────┤
│  ✗ Don't know   Learning   Know ✓  │
└─────────────────────────────────────┘
```

Three-state tracking: **Don't know** / **Learning** / **Know this**

Flipped side shows answer + optional explanation. Swipe left/right or tap buttons to mark. Progress tracked in GRDB per card (`FlashcardStatus`).

Study mode filters: "All", "Unknown only", "Learning only" — selectable in toolbar.

### 5.8 People List View

Simple searchable list of all people in the tree, sorted alphabetically. Tap → Person Profile. Alternative to navigating the visual tree.

### 5.9 Decks View

List of all generated flashcard decks with:

- Perspective person name
- Card count
- Generation date
- Progress (X known / Y learning / Z unknown)
- Tap → Study mode or export PDF

### 5.10 Settings Screen

```
AI PROVIDER
 ● Apple Intelligence (recommended)
 ○ Anthropic
   API Key: [••••••••••••]  [Change]
   Model:   [claude-sonnet-4-6 ▾]
 ○ OpenAI
   API Key: [••••••••••••]  [Change]
   Model:   [gpt-4o ▾]

FAMILY TREE
 Root Person: [Mary Smith ▾]
 Export as .ged file
 Import .ged file

DATA
 Export all data (zip)
 Delete all data (confirmation required)

ACCESSIBILITY
 Reduce motion (disables tree animations)

ABOUT
 Version, build, privacy policy, etc.
```

---

## 6. GEDCOM Support

### 6.1 Import

- iOS document picker filters for `.ged` files
- Parser reads INDI (individual) and FAM (family) records
- Maps to `Person` + `Relationship` GRDB records
- OBJE (multimedia) records noted but files not auto-imported (user prompted to add manually)
- **Progress reporting:** For large files (1000+ individuals), show a progress bar with count
- **Error handling:** Malformed records are skipped with a summary shown after import ("Imported 847 of 850 people. 3 records had errors.")
- Conflict resolution: if a person appears to match an existing record (same first+last name + birth year within 2 years), prompt user to merge or keep separate
- Parser implemented in pure Swift, no dependencies
- **GEDCOM versions supported:** 5.5.1 (primary), 7.0 (best-effort — parse the subset of tags that map to our data model, warn on unsupported tags)

### 6.2 Export

- Generates valid GEDCOM 5.5.1 output
- All persons and relationships exported
- Notes field exported to NOTE records
- Attachment filenames referenced in OBJE records
- Offered as share sheet (AirDrop, Mail, Files, etc.)

---

## 7. Flashcard Generation Logic

### 7.1 Relationship Traversal

`FlashcardGenerator` takes a perspective person ID and:

1. BFS traverses the tree up to 4 hops
2. For each reachable person, computes colloquial relationship label (including gender-neutral and step/adoptive variants)
3. Generates a question/answer pair
4. Optionally adds an explanation with additional context

### 7.2 Question Templates

```
1-hop:
  "Who is your [relationship]?" → [Name]

2-hop:
  "Who is your [rel1]'s [rel2]?" → [Name] (your [computed label])

3-hop:
  "Who is your [rel1]'s [rel2]'s [rel3]?" → [Name] (your [computed label])

4-hop:
  "Who is your [rel1]'s [rel2]'s [rel3]'s [rel4]?" → [Name] (your [computed label])
```

### 7.3 AI Role in Generation

The AI provider receives the traversal results and:

- Writes natural-sounding question phrasing (varying templates to avoid monotony)
- Writes the explanation field with biographical context pulled from person notes
- Returns structured `[GeneratedFlashcard]` array

### 7.4 Output Format (Structured)

```swift
@Generable
struct GeneratedFlashcard: Codable, Sendable {
    let question: String
    let answer: String
    let explanation: String?
    let relationshipChain: String   // "father → sister" for debugging
}
```

---

## 8. PDF Export

Generated via **PDFKit** (no server, no third-party library).

- Card size: 4x6 inches
- Front: question centered, deck name and card number in footer
- Back: answer large, explanation smaller below, person name in header
- One card per page (front then back, alternating) for duplex home printing
- Exported via share sheet

---

## 9. AI Provider Implementation Details

### 9.1 Apple Intelligence (Foundation Models)

```swift
import FoundationModels

struct AppleIntelligenceProvider: AIProvider {
    private let session = LanguageModelSession()

    func chat(messages: [AIMessage]) async throws -> String {
        // Convert to Foundation Models format and generate
    }

    func chatStream(messages: [AIMessage]) -> AsyncThrowingStream<String, Error> {
        // Stream tokens from LanguageModelSession
    }

    func structured<T: Decodable & Sendable>(
        prompt: String,
        schema: AISchema,
        as type: T.Type
    ) async throws -> T {
        // Use @Generable macro for structured output
        // schema parameter is ignored — compile-time type generation
    }

    var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }
}
```

### 9.2 Anthropic

- Endpoint: `https://api.anthropic.com/v1/messages`
- Auth: `x-api-key` header, key from Keychain
- Streaming: SSE via `URLSession` bytes stream
- Structured output: JSON mode with schema in system prompt
- Models offered in Settings: `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`
- Retry: exponential backoff on 429/5xx, max 3 attempts

### 9.3 OpenAI

- Endpoint: `https://api.openai.com/v1/chat/completions`
- Auth: `Authorization: Bearer {key}` header, key from Keychain
- Streaming: SSE via `URLSession` bytes stream
- Structured output: `response_format: { type: "json_object" }`
- Models offered in Settings: `gpt-4o`, `gpt-4o-mini`, `o3-mini`
- Retry: exponential backoff on 429/5xx, max 3 attempts

---

## 10. Mac Catalyst Considerations

- Use `NavigationSplitView` throughout — collapses correctly on iPhone, expands on iPad/Mac
- Document picker works on Mac via Catalyst
- Keychain works identically
- PDFKit works identically
- Visual tree canvas: ensure mouse scroll = pan, trackpad pinch = zoom
- Context menus (long press) → right-click on Mac automatically via Catalyst
- Menu bar: add File → Import .ged, File → Export .ged

---

## 11. Accessibility

| Feature | Implementation |
|---------|---------------|
| VoiceOver | All tree nodes, flashcards, and buttons have accessibility labels. Tree nodes read as "[Name], [relationship to root], [birth–death years]" |
| Dynamic Type | All text uses system text styles; layouts adapt to larger sizes |
| Reduced Motion | Tree animations (zoom, pan, card flip) respect `UIAccessibility.isReduceMotionEnabled`. Setting also available in app Settings. |
| Color contrast | All text meets WCAG AA contrast ratios against backgrounds |
| Keyboard navigation (Mac) | Arrow keys navigate tree nodes; Enter opens profile; Escape dismisses sheets |

---

## 12. Privacy

- All family data stored on device only
- No analytics, no crash reporting (unless user opts in)
- API keys stored in Keychain only, never logged
- When using external AI provider: conversation content (names, relationships) is sent to Anthropic/OpenAI — user must consent to this in onboarding (Section 5.1 step 3)
- Privacy policy required for App Store submission, must name Anthropic and OpenAI as potential third-party data recipients per Apple's November 2025 AI transparency guidelines
- Optional encrypted iCloud backup (future — not in v1, but data model should not preclude it)

---

## 13. Undo / Data Safety

- **Undo for destructive actions:** Deleting a person shows an undo toast (Snackbar) for 5 seconds before the cascade delete executes. If the user taps "Undo", the delete is cancelled.
- **Relationship deletion:** Same undo toast pattern.
- **Attachment deletion:** Files are moved to a `.trash/` directory and purged after 30 days or on next app launch (whichever is later).
- **"Delete all data"** in Settings requires typing "DELETE" to confirm.

---

## 14. File Structure

```
KinFlash/
├── App/
│   └── KinFlashApp.swift
├── Models/
│   ├── Person.swift
│   ├── Relationship.swift
│   ├── Attachment.swift
│   ├── Flashcard.swift
│   ├── FlashcardDeck.swift
│   └── AppSettings.swift
├── Database/
│   ├── DatabaseManager.swift
│   └── Migrations/
├── AI/
│   ├── AIProvider.swift            ← protocol + AIMessage + AISchema
│   ├── AIProviderRouter.swift
│   ├── AppleIntelligenceProvider.swift
│   ├── AnthropicProvider.swift
│   └── OpenAIProvider.swift
├── Services/
│   ├── InterviewService.swift
│   ├── TreeService.swift
│   ├── RelationshipResolver.swift
│   ├── FlashcardGenerator.swift
│   ├── GEDCOMParser.swift
│   ├── GEDCOMExporter.swift
│   └── AttachmentManager.swift
├── Views/
│   ├── Onboarding/
│   │   ├── WelcomeView.swift
│   │   ├── AISetupView.swift
│   │   ├── PrivacyConsentView.swift
│   │   └── StartView.swift
│   ├── Tree/
│   │   ├── TreeCanvasView.swift
│   │   ├── PersonCardView.swift
│   │   └── TreeLayoutEngine.swift
│   ├── Profile/
│   │   ├── PersonProfileView.swift
│   │   ├── PhotoStripView.swift
│   │   └── DocumentListView.swift
│   ├── Interview/
│   │   └── InterviewView.swift
│   ├── Flashcards/
│   │   ├── FlashcardGenerationView.swift
│   │   ├── StudyModeView.swift
│   │   └── DeckListView.swift
│   └── Settings/
│       └── SettingsView.swift
├── Utilities/
│   ├── KeychainManager.swift
│   └── PDFExporter.swift
└── Tests/
    ├── RelationshipResolverTests.swift
    ├── TreeLayoutEngineTests.swift
    ├── GEDCOMParserTests.swift
    ├── GEDCOMExporterTests.swift
    ├── FlashcardGeneratorTests.swift
    ├── DataValidationTests.swift
    └── DatabaseMigrationTests.swift
```

---

## 15. Test Plan

| Test suite | What it covers |
|------------|---------------|
| `RelationshipResolverTests` | All hop counts 1–4, gender-neutral labels, step/adoptive prefixes, cycle rejection |
| `TreeLayoutEngineTests` | Generation assignment, spouse pairing, multi-marriage, disconnected subtrees, pedigree collapse |
| `GEDCOMParserTests` | Sample GEDCOM import (section 17), malformed records, GEDCOM 7.0 subset |
| `GEDCOMExporterTests` | Round-trip: import → export → re-import yields identical data |
| `FlashcardGeneratorTests` | Correct card count per tree topology, question template coverage |
| `DataValidationTests` | Cycle detection, self-relationship rejection, duplicate relationship rejection |
| `DatabaseMigrationTests` | Empty database boots, future migrations apply cleanly |

All tests use an in-memory GRDB database. No AI provider needed — flashcard generation tests use a mock `AIProvider`.

---

## 16. Build Order for Claude Code

Implement in this sequence to keep things testable at each step:

1. **GRDB schema + migrations** — all models including `AppSettings`, foreign keys, empty database boots
2. **AIProvider protocol + all three implementations** — testable in isolation with mock
3. **GEDCOMParser** — import the sample .ged file (section 17), verify GRDB output
4. **RelationshipResolver** — unit testable pure logic, including in-law and step paths
5. **Data validation (TreeService)** — cycle detection, duplicate prevention
6. **TreeLayoutEngine** — positions nodes correctly, no UI yet
7. **TreeCanvasView + PersonCardView** — renders layout engine output with gestures
8. **PersonProfileView** — static, no attachments yet
9. **AttachmentManager + photo/document UI** — add to ProfileView
10. **InterviewService + InterviewView** — AI-powered with streaming, uses provider protocol
11. **FlashcardGenerator + StudyModeView** — three-state tracking
12. **PDFExporter**
13. **Settings screen** — provider switching, root person selection, GEDCOM import/export
14. **Onboarding flow** — including privacy consent
15. **Accessibility pass** — VoiceOver labels, Dynamic Type, reduced motion
16. **Mac Catalyst polish** — menu bar, scroll/zoom, window sizing, keyboard navigation
17. **Test suite** — all tests in section 15

---

## 17. Sample GEDCOM for Testing

```gedcom
0 HEAD
1 SOUR KinFlash
1 GEDC
2 VERS 5.5.1
0 @I1@ INDI
1 NAME Robert /Smith/
1 SEX M
1 BIRT
2 DATE 15 FEB 1920
2 PLAC Detroit, Michigan
1 DEAT
2 DATE 8 NOV 1990
1 FAMS @F1@
0 @I2@ INDI
1 NAME Helen /Brown/
1 SEX F
1 BIRT
2 DATE 22 AUG 1922
2 PLAC Detroit, Michigan
1 DEAT
2 DATE 1 MAR 2005
1 FAMS @F1@
0 @I3@ INDI
1 NAME John /Smith/
1 SEX M
1 BIRT
2 DATE 12 JUN 1945
2 PLAC Chicago, Illinois
1 DEAT
2 DATE 3 MAR 2018
1 FAMC @F1@
1 FAMS @F2@
0 @I4@ INDI
1 NAME Carol /Smith/
1 SEX F
1 BIRT
2 DATE 7 OCT 1948
2 PLAC Chicago, Illinois
1 FAMC @F1@
0 @I5@ INDI
1 NAME Mary /Jones/
1 SEX F
1 BIRT
2 DATE 3 MAR 1948
1 FAMS @F2@
0 @I6@ INDI
1 NAME Michael /Smith/
1 SEX M
1 BIRT
2 DATE 15 SEP 1970
1 FAMC @F2@
0 @I7@ INDI
1 NAME David /Smith/
1 SEX M
1 BIRT
2 DATE 4 JAN 1973
1 FAMC @F2@
0 @F1@ FAM
1 HUSB @I1@
1 WIFE @I2@
1 CHIL @I3@
1 CHIL @I4@
0 @F2@ FAM
1 HUSB @I3@
1 WIFE @I5@
1 CHIL @I6@
1 CHIL @I7@
0 TRLR
```

This sample covers 3 generations (7 people, 2 families) and tests:
- Parent-child relationships across two family units
- Sibling derivation from shared FAM records
- Spouse relationships
- Both living and deceased persons
- Birth places and death dates
- Aunt Carol (John's sibling) for 2-hop relationship testing
- Cousin relationships (Michael/David to any future children of Carol) for extension testing

---

*Spec version 2.0 — KinFlash — ready for Claude Code implementation*
