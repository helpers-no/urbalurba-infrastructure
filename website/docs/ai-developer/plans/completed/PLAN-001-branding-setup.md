# Plan: Set Up UIS Branding

> **IMPLEMENTATION RULES:** Before implementing this plan, read and follow:
> - [WORKFLOW.md](../../WORKFLOW.md) - The implementation process
> - [PLANS.md](../../PLANS.md) - Plan structure and best practices

**Status:** Completed

**Goal**: Establish complete branding assets for the UIS documentation site.

**Last Updated**: 2026-01-19

**Priority**: High (blocks other documentation work)

---

## Overview

Set up the brand folder structure and create/collect all branding assets needed for the UIS Docusaurus site, following the pattern established by DevContainer Toolbox.

---

## Phase 1: Brand Folder Structure

### Tasks

- [x] 1.1 Create `website/static/img/brand/` folder
- [x] 1.2 Copy and adapt main logo (`uis-logo-green.svg`) with SovereignSky colors
- [x] 1.3 Update `docusaurus.config.ts` to use new logo
- [x] 1.4 Create logo variant for dark mode (`uis-logo-teal.svg`)
- [x] 1.5 Create text logo similar to DCT's `cube-dct-green.svg`:
  - Create `uis-text-green.svg` with pyramid logo + "UIS" text
  - Use SovereignSky green (#3a8f5e)
  - Similar layout: logo on left, text on right
- [x] 1.6 Adapt publish scripts from DCT:
  - `publish-logo.sh` - Copies SVG logo to Docusaurus location (`static/img/logo.svg`)
  - `publish-favicon.sh` - Creates multi-size favicon.ico from SVG (16x16, 32x32, 48x48)
  - Change default source to `uis-logo-green.svg`
- [x] 1.7 Copy other branding assets from `~/Downloads/uis-branding/` to brand folder

### Validation

User confirms brand folder structure is correct.

---

## Phase 2: Animated Hero SVG

### Overview

Create an animated SVG for the homepage hero section, similar to DCT's FloatingCubes component. The animation shows services being added to the UIS cloud, communicating that the platform can run many services.

### Design Description

- **Background**: Cloud shape from `uis-logo-green.svg`
- **Inside cloud**: Pyramid of cubes (service icons) with same look/feel as DCT hero
- **Below cloud**: Row of cubes representing available services waiting to be deployed
- **Animation**: Cubes float up from the row below and settle into positions inside the cloud
- **Message**: Visually demonstrates "complete datacenter on your laptop" concept

### Tasks

- [x] 2.1 Create `FloatingCubes` React component (adapt from DCT)
  - Located in `website/src/components/FloatingCubes/`
  - `index.tsx` - Main component with SVG and animations
  - `styles.module.css` - Component styles
- [x] 2.2 Create animated hero SVG (`uis-hero-animation.svg`):
  - Cloud outline as container/background
  - 5 cubes inside cloud (pyramid arrangement)
  - 5 cubes floating outside cloud (service queue)
  - CSS animations for cube movement
- [x] 2.3 Implement cube animation logic:
  - AI cube animates from outside into top slot
  - Floating cubes bob up and down
  - Subtle idle animation on stacked cubes
  - Staggered timing for natural feel
- [x] 2.4 Integrate hero into homepage (`src/pages/index.tsx`)
- [ ] 2.5 Test animations across browsers (Chrome, Firefox, Safari)
- [x] 2.6 Ensure responsive behavior on mobile

### Reference Files

- DCT component: `devcontainer-toolbox/website/src/components/FloatingCubes/index.tsx`
- UIS logo: `website/static/img/brand/uis-logo-green.svg`
- Concept files: `~/Downloads/uis-branding/uis-animated-hero-v2.svg`, `uis-swap-animation.svg`

### Validation

User confirms hero animation displays correctly and conveys the intended message.

---

## Phase 3: Category Logos

### Decision: Harmonize with DevContainer Toolbox

Category logos use [Heroicons](https://heroicons.com/) (MIT License) with SovereignSky green (#3a8f5e).
This matches the approach used in DCT for consistency across SovereignSky projects.

**Reused from DCT (5 icons):**
| UIS Logo | DCT Source | Heroicon |
|----------|------------|----------|
| ai-logo.svg | ai-tools-logo.svg | Sparkles |
| monitoring-logo.svg | background-services-logo.svg | ServerStack |
| datascience-logo.svg | data-analytics-logo.svg | ChartBar |
| core-logo.svg | infra-config-logo.svg | Cog |
| development-logo.svg | language-dev-logo.svg | Code |

**Created new for UIS (5 icons):**
| UIS Logo | Heroicon |
|----------|----------|
| authentication-logo.svg | ShieldCheck |
| databases-logo.svg | CircleStack |
| queues-logo.svg | QueueList |
| search-logo.svg | MagnifyingGlass |
| management-logo.svg | AdjustmentsHorizontal |

### Tasks

- [x] 3.1 Create `website/static/img/categories/` folder
- [x] 3.2 Create `website/static/img/categories/src/` for SVG sources
- [x] 3.3 Create/collect category logos (10 total, SVG preferred):
  - [x] ai-logo.svg - AI & Machine Learning (from DCT)
  - [x] authentication-logo.svg - Authentication & SSO (new)
  - [x] databases-logo.svg - Databases (new)
  - [x] monitoring-logo.svg - Observability & Monitoring (from DCT)
  - [x] queues-logo.svg - Message Queues & Caching (new)
  - [x] search-logo.svg - Search & Indexing (new)
  - [x] datascience-logo.svg - Data Science & Analytics (from DCT)
  - [x] core-logo.svg - Core Infrastructure (from DCT)
  - [x] management-logo.svg - Management Tools (new)
  - [x] development-logo.svg - Development Tools (from DCT)
- [x] 3.4 Create `LOGO-SOURCES.md` documenting icon sources
- [x] 3.5 Verify `categories.json` logo paths match created files

### Validation

User confirms category logos match SovereignSky branding.

---

## Phase 4: Service Logos

### Complete Service List

Services identified from `provision-host/kubernetes/` scripts and manifests:

**Core Infrastructure (01-core):**
| Service | Logo File | Source |
|---------|-----------|--------|
| traefik | traefik-logo.svg | [traefik.io](https://traefik.io/) |
| nginx | nginx-logo.svg | [nginx.org](https://nginx.org/) |

**Databases (02-databases):**
| Service | Logo File | Source |
|---------|-----------|--------|
| postgresql | postgresql-logo.svg | [postgresql.org/media](https://www.postgresql.org/media/img/) |
| mysql | mysql-logo.svg | [mysql.com](https://www.mysql.com/) |
| mongodb | mongodb-logo.svg | [mongodb.com](https://www.mongodb.com/) |
| qdrant | qdrant-logo.svg | [qdrant.tech](https://qdrant.tech/) |

**Message Queues (03-queues):**
| Service | Logo File | Source |
|---------|-----------|--------|
| redis | redis-logo.svg | [redis.io](https://redis.io/) |
| rabbitmq | rabbitmq-logo.svg | [rabbitmq.com](https://www.rabbitmq.com/) |

**Search (04-search):**
| Service | Logo File | Source |
|---------|-----------|--------|
| elasticsearch | elasticsearch-logo.svg | [elastic.co/brand](https://www.elastic.co/brand) |

**API Management (05-apim):**
| Service | Logo File | Source |
|---------|-----------|--------|
| gravitee | gravitee-logo.svg | [gravitee.io](https://www.gravitee.io/) |

**Management Tools (06-management):**
| Service | Logo File | Source |
|---------|-----------|--------|
| pgadmin | pgadmin-logo.svg | [pgadmin.org](https://www.pgadmin.org/) |
| redisinsight | redisinsight-logo.svg | [redis.io/insight](https://redis.io/insight/) |

**AI & ML (07-ai):**
| Service | Logo File | Source |
|---------|-----------|--------|
| openwebui | openwebui-logo.svg | [openwebui.com](https://openwebui.com/) |
| ollama | ollama-logo.svg | [ollama.ai](https://ollama.ai/) |
| litellm | litellm-logo.svg | [litellm.ai](https://litellm.ai/) |
| tika | tika-logo.svg | [tika.apache.org](https://tika.apache.org/) |

**Development Tools (08-development):**
| Service | Logo File | Source |
|---------|-----------|--------|
| argocd | argocd-logo.svg | [CNCF Artwork](https://github.com/cncf/artwork/tree/main/projects/argo) |

**Network (09-network):**
| Service | Logo File | Source |
|---------|-----------|--------|
| tailscale | tailscale-logo.svg | [tailscale.com](https://tailscale.com/) |
| cloudflare | cloudflare-logo.svg | [cloudflare.com](https://www.cloudflare.com/) |

**Data Science (10-datascience):**
| Service | Logo File | Source |
|---------|-----------|--------|
| spark | spark-logo.svg | [Apache Foundation](https://www.apache.org/logos/) |
| jupyterhub | jupyterhub-logo.svg | [jupyter.org](https://jupyter.org/) |
| unity-catalog | unity-catalog-logo.svg | [unitycatalog.io](https://www.unitycatalog.io/) |

**Monitoring (11-monitoring):**
| Service | Logo File | Source |
|---------|-----------|--------|
| prometheus | prometheus-logo.svg | [CNCF Artwork](https://github.com/cncf/artwork/tree/main/projects/prometheus) |
| tempo | tempo-logo.svg | [CNCF Artwork](https://github.com/cncf/artwork) |
| loki | loki-logo.svg | [CNCF Artwork](https://github.com/cncf/artwork) |
| otel-collector | otel-collector-logo.svg | [CNCF Artwork](https://github.com/cncf/artwork/tree/main/projects/opentelemetry) |
| grafana | grafana-logo.svg | [grafana.com/brand](https://grafana.com/brand-guidelines/) |

**Authentication (12-auth):**
| Service | Logo File | Source |
|---------|-----------|--------|
| authentik | authentik-logo.svg | [goauthentik.io](https://goauthentik.io/) |

**Total: 28 services**

### Tasks

- [x] 4.1 Create `website/static/img/services/` folder
- [x] 4.2 Create `website/static/img/services/src/` for original sources
- [x] 4.3 Collect service logos (SVG preferred, PNG fallback):
  - **Core Infrastructure (2):**
    - [x] traefik-logo.svg
    - [x] nginx-logo.svg
  - **Databases (4):**
    - [x] postgresql-logo.svg
    - [x] mysql-logo.svg
    - [x] mongodb-logo.svg
    - [x] qdrant-logo.svg
  - **Message Queues (2):**
    - [x] redis-logo.svg
    - [x] rabbitmq-logo.svg
  - **Search (1):**
    - [x] elasticsearch-logo.svg
  - **API Management (1):**
    - [x] gravitee-logo.svg
  - **Management Tools (2):**
    - [x] pgadmin-logo.png
    - [x] redisinsight-logo.svg
  - **AI & ML (4):**
    - [x] openwebui-logo.png
    - [x] ollama-logo.svg
    - [x] litellm-logo.svg
    - [x] tika-logo.svg
  - **Development Tools (1):**
    - [x] argocd-logo.svg
  - **Network (2):**
    - [x] tailscale-logo.svg
    - [x] cloudflare-logo.svg
  - **Data Science (3):**
    - [x] spark-logo.svg
    - [x] jupyterhub-logo.svg
    - [x] unity-catalog-logo.png
  - **Monitoring (5):**
    - [x] prometheus-logo.svg
    - [x] tempo-logo.svg
    - [x] loki-logo.png
    - [x] otel-collector-logo.svg
    - [x] grafana-logo.svg
  - **Authentication (1):**
    - [x] authentik-logo.svg
- [x] 4.4 Update `services.json` with correct logo paths
- [x] 4.5 Update `LOGO-SOURCES.md` with service logo sources

### Logo Source Priority

1. **CNCF Artwork** - Prometheus, Loki, Tempo, Argo CD, OpenTelemetry (Apache 2.0)
2. **Official brand pages** - Grafana, PostgreSQL, Redis, Elastic, etc.
3. **Simple Icons** - Fallback for common tech logos ([simpleicons.org](https://simpleicons.org/))
4. **Devicon** - Programming/dev tool icons ([devicon.dev](https://devicon.dev/))

### Validation

User confirms service logos are available for all 28 services.

---

## Phase 5: Stacks Setup

### Overview

Create visual representation and documentation for service stacks - groups of services that work together as a unit. Stacks are defined in `stacks.json` and show installation order and dependencies.

### Current Stacks (from stacks.json)

| Stack ID | Name | Services |
|----------|------|----------|
| observability | Observability Stack | prometheus → tempo → loki → otel-collector (opt) → grafana |
| ai-local | Local AI Stack | ollama → litellm (opt) → openwebui |
| datascience | Data Science Stack | spark → jupyterhub → unity-catalog (opt) |

### Tasks

- [x] 5.1 Create stack logos/icons for each stack:
  - [x] `observability-stack-logo.svg` - Metrics/logs/traces visualization
  - [x] `ai-local-stack-logo.svg` - Neural network/processor icon
  - [x] `datascience-stack-logo.svg` - Beaker with data dots
- [x] 5.2 Create `website/static/img/stacks/` folder structure
- [ ] 5.3 Design stack card component for homepage or docs (future):
  - Show stack name and description
  - List component services with logos
  - Indicate installation order (position)
  - Mark optional components
- [ ] 5.4 Create stack documentation page template (future):
  - Overview of what the stack provides
  - Prerequisites and dependencies
  - Installation instructions (which scripts to activate)
  - Configuration options
- [x] 5.5 Update `stacks.json` with logo references
- [ ] 5.6 Create React component for displaying stacks (optional/future):
  - `website/src/components/StackCard/index.tsx`
  - Shows services in order with visual flow

### Stack Logo Design

Used **Heroicons style** (option 3) to match category logos with SovereignSky green (#3a8f5e).

### Validation

User confirms stacks are visually represented and documented.

---

## Phase 6: Social Card and Favicon

### Tasks

- [x] 6.1 Create `social-card-background.png` (similar to DCT's version)
  - Generated with Gemini AI, cleaned with `remove-gemini-stars.sh`
  - 1344x768 pixels
  - Cloud with cubes visual, space for text on right side
- [x] 6.2 Adapt `create-social-card.sh` script from DCT:
  - Title: "Urbalurba\nInfrastructure\nStack"
  - Tagline: "Complete datacenter\non your laptop."
  - Logo: `uis-text-green.svg` in bottom right
  - Uses ImageMagick to composite background + text + logo
- [x] 6.3 Adapt `publish-social-card.sh` script from DCT:
  - Outputs only `static/img/social-card.jpg` (optimized JPG)
  - Removed PNG output to avoid duplication
- [x] 6.4 Run scripts to generate `social-card-generated.png`
- [x] 6.5 Create favicon from UIS logo (`website/static/img/favicon.ico`)
- [x] 6.6 Verify social card and favicon in Docusaurus config
- [x] 6.7 Create `remove-gemini-stars.sh` script to clean AI watermarks
  - Supports `-left` and `-right` flags for corner selection
  - Validates image size for social cards
- [x] 6.8 Add `README.md` documenting brand folder workflow

### Validation

User confirms social card appears correctly in link previews.

---

## Phase 7: Component Infrastructure

### Overview

Set up the foundation for displaying services, categories, and stacks. Adapt components from DevContainer Toolbox (DCT) project.

### Reference: DCT Component Architecture

DCT uses these components at `/Users/terje.christensen/learn/projects-2025/devcontainer-toolbox/website/src/components/`:
- **ToolCard** → adapt to **ServiceCard** (64px logo + title + 2-line abstract + tags)
- **CategoryCard** → reuse (48px logo + title + service count)
- **ToolGrid** → adapt to **ServiceGrid** (responsive 1-4 column grid)
- **CategoryGrid** → reuse (responsive grid of categories)
- **RelatedTools** → adapt to **RelatedServices** (horizontal scroll)

### Tasks

- [x] 7.1 Create TypeScript interfaces for UIS data types:
  - `src/types/service.ts` - Service interface
  - `src/types/category.ts` - Category interface
  - `src/types/stack.ts` - Stack interface
  - `src/types/index.ts` - Central exports
- [x] 7.2 Create utility functions:
  - `src/utils/paths.ts` - URL generation for services/categories
  - `src/utils/data.ts` - Data loading helpers
  - `src/utils/index.ts` - Central exports
- [x] 7.3 CSS variables already in place from DCT adaptation in custom.css

### Files to Create

```
website/src/
├── types/
│   ├── service.ts
│   ├── category.ts
│   └── stack.ts
└── utils/
    ├── paths.ts
    └── data.ts
```

### Validation

TypeScript types compile without errors.

---

## Phase 8: Service & Category Components

### Overview

Create the card and grid components for displaying services and categories.

### Tasks

- [x] 8.1 Create ServiceCard component:
  - `src/components/ServiceCard/index.tsx`
  - `src/components/ServiceCard/styles.module.css`
  - Layout: 64px logo | title + 2-line abstract + tags
  - Hover effect: shadow lift
  - Links to service detail page (using docs field from services.json)
- [x] 8.2 Create ServiceGrid component:
  - `src/components/ServiceGrid/index.tsx`
  - `src/components/ServiceGrid/styles.module.css`
  - Groups services by category with section headers
  - Responsive: 1 col (mobile) → 4 col (desktop)
- [x] 8.3 Create CategoryCard component:
  - `src/components/CategoryCard/index.tsx`
  - `src/components/CategoryCard/styles.module.css`
  - Layout: 48px logo | title + abstract + service count badge
  - Links to category section on services page
- [x] 8.4 Create CategoryGrid component:
  - `src/components/CategoryGrid/index.tsx`
  - `src/components/CategoryGrid/styles.module.css`
  - Auto-counts services per category
  - Sorts by category order
- [x] 8.5 Create RelatedServices component:
  - `src/components/RelatedServices/index.tsx`
  - `src/components/RelatedServices/styles.module.css`
  - Horizontal scroll of mini service cards
  - Ready for use on service detail pages

### Files to Create

```
website/src/components/
├── ServiceCard/
│   ├── index.tsx
│   └── styles.module.css
├── ServiceGrid/
│   ├── index.tsx
│   └── styles.module.css
├── CategoryCard/
│   ├── index.tsx
│   └── styles.module.css
├── CategoryGrid/
│   ├── index.tsx
│   └── styles.module.css
└── RelatedServices/
    ├── index.tsx
    └── styles.module.css
```

### Validation

Components render correctly in isolation (Storybook or test page).

---

## Phase 9: Stack Components

### Overview

Create StackCard with service flow diagram showing installation order.

### Design

```
┌─────────────────────────────────────────────────────────┐
│  [Stack Logo]  Observability Stack                      │
│                Complete monitoring with metrics...       │
│                                                         │
│  prometheus → tempo → loki → otel-collector* → grafana  │
│      ⬤         ⬤      ⬤         ○              ⬤       │
│                                                         │
│  * optional                                             │
└─────────────────────────────────────────────────────────┘
```

### Tasks

- [x] 9.1 Create StackCard component:
  - `src/components/StackCard/index.tsx`
  - `src/components/StackCard/styles.module.css`
  - Header: stack logo + name + description
  - Flow diagram: service logos with arrows between them
  - Optional services shown with dashed border and dimmed
  - Service names shown optionally
- [x] 9.2 Create StackGrid component:
  - `src/components/StackGrid/index.tsx`
  - `src/components/StackGrid/styles.module.css`
  - Responsive grid (1-3 columns)
- [x] 9.3 Create ServiceFlowDiagram sub-component:
  - `src/components/ServiceFlowDiagram/index.tsx`
  - `src/components/ServiceFlowDiagram/styles.module.css`
  - Renders service logos in order with SVG arrows
  - Handles optional services styling (dashed border, dimmed)

### Files to Create

```
website/src/components/
├── StackCard/
│   ├── index.tsx
│   └── styles.module.css
├── StackGrid/
│   ├── index.tsx
│   └── styles.module.css
└── ServiceFlowDiagram/
    ├── index.tsx
    └── styles.module.css
```

### Validation

Stack cards display with correct service flow diagrams.

---

## Phase 10: Services Page

### Overview

Create the `/services` page displaying all services grouped by category, with stacks section.

### Page Structure

```
/services
├── Header: "Infrastructure Services"
├── Stacks Section: "Service Stacks" (StackGrid)
├── Categories Section: "Browse by Category" (CategoryGrid)
└── Per-Category Sections:
    ├── "AI & Machine Learning" (ServiceGrid category="AI")
    ├── "Authentication & SSO" (ServiceGrid category="AUTHENTICATION")
    ├── ... (all 10 categories)
```

### Tasks

- [x] 10.1 Create services page:
  - `src/pages/services.tsx`
  - `src/pages/services.module.css`
- [x] 10.2 Implement page sections:
  - Header section with title and description
  - Categories section with CategoryGrid
  - Pre-configured Stacks section with StackGrid
  - All Services section with ServiceGrid (grouped by category)
- [x] 10.3 Add anchor links for categories (e.g., `/services#ai`)
  - Anchors created dynamically by ServiceGrid component
- [ ] 10.4 Add "View All" functionality if categories have many services (future enhancement)

### Files to Create

```
website/src/pages/
├── services.tsx
└── services.module.css
```

### Validation

Services page displays all services grouped correctly.

---

## Phase 11: Service Detail Pages

### Overview

Create individual detail pages for each service, linked from ServiceCard.

### URL Structure

Services link to existing docs where available:
- `/docs/services/ai/openwebui` (if doc exists)
- `/docs/services/monitoring/prometheus` (if doc exists)

### Tasks

- [x] 11.1 Service detail pages:
  - Existing docs in `docs/packages/[category]/` already serve as detail pages
  - ServiceCard links directly to docs field from services.json
- [x] 11.2 Path utility created (src/utils/paths.ts):
  - getCategoryFolder, getServicePath, getCategoryPath functions
  - ServiceCard uses docs field directly from services.json
- [x] 11.3 RelatedServices component ready:
  - Available via `import RelatedServices from '@site/src/components/RelatedServices'`
  - Can be added to doc pages as needed
- [x] 11.4 ServiceCard links work:
  - Links to docs path specified in services.json
  - Verified all referenced docs exist

### Path Mapping

| Category | Docs Folder |
|----------|-------------|
| AI | `/docs/services/ai/` |
| AUTHENTICATION | `/docs/services/authentication/` |
| DATABASES | `/docs/services/databases/` |
| MONITORING | `/docs/services/monitoring/` |
| QUEUES | `/docs/services/queues/` |
| SEARCH | `/docs/services/search/` |
| DATASCIENCE | `/docs/services/datascience/` |
| CORE | `/docs/services/core/` |
| MANAGEMENT | `/docs/services/management/` |
| DEVELOPMENT | `/docs/services/development/` |

### Validation

Service cards link to correct detail pages or external URLs.

---

## Phase 12: Final Verification

### Tasks

- [x] 12.1 Verify all logo references in JSON files are valid
  - All 28 service logos verified
  - All 10 category logos verified
  - All 3 stack logos verified
- [x] 12.2 Test site builds without errors
  - Build succeeds with `npm run build`
  - TypeScript compiles without errors (`npx tsc --noEmit`)
  - Anchor warnings for dynamic content (work at runtime)
- [ ] 12.3 Visual check of all components on services page (manual)
- [ ] 12.4 Test responsive design (mobile, tablet, desktop) (manual)
- [ ] 12.5 Verify all links work (internal docs, external URLs) (manual)
- [ ] 12.6 Test light/dark mode for all components (manual)
- [ ] 12.7 Check accessibility (alt text, keyboard navigation) (manual)

### Validation

User confirms site builds and all pages display correctly.

---

## Acceptance Criteria

### Branding (Phases 1-6) ✓
- [x] Brand folder structure matches DCT pattern
- [x] Main logo displays correctly in navbar
- [x] Dark mode logo variant exists
- [x] Category logos created (10) - Heroicons with SovereignSky green
- [x] Service logos created (28 services - 24 SVG, 4 PNG)
- [x] Stack logos/visuals created (3 stacks)
- [x] Social card image created
- [x] Favicon updated
- [x] Data model defined (categories, services, stacks with JSON-LD)
- [x] JSON schemas created for validation
- [x] Service dependencies captured (requires[])
- [x] Service stacks defined (observability, ai-local, datascience)
- [x] Animated hero displays on homepage with cube animations

### Components (Phases 7-9) ✓
- [x] TypeScript interfaces created for all data types
- [x] ServiceCard component displays service with logo, title, abstract, tags
- [x] CategoryCard component displays category with service count
- [x] StackCard component displays service flow diagram
- [x] Grid components support responsive layouts
- [x] Components support light/dark mode (using CSS variables)

### Pages (Phases 10-11) ✓
- [x] /services page displays all services grouped by category
- [x] Stacks section shows service flow diagrams
- [x] Category navigation works with anchor links
- [x] Service cards link to detail pages (docs field from services.json)
- [x] RelatedServices component available for doc pages

### Final (Phase 12) - In Progress
- [x] Site builds without errors
- [ ] All links work correctly (manual verification needed)
- [ ] Responsive design verified on mobile/tablet/desktop (manual)
- [ ] Accessibility requirements met (manual)

---

## Files to Create/Modify

**Brand Assets (Created):**
- [x] `website/static/img/brand/uis-logo-teal.svg`
- [x] `website/static/img/brand/uis-text-green.svg`
- [x] `website/static/img/brand/social-card-background.png`
- [x] `website/static/img/brand/social-card-generated.png`
- [x] `website/static/img/brand/create-social-card.sh`
- [x] `website/static/img/brand/publish-social-card.sh`
- [x] `website/static/img/brand/publish-logo.sh`
- [x] `website/static/img/brand/publish-favicon.sh`
- [x] `website/static/img/brand/remove-gemini-stars.sh`
- [x] `website/static/img/brand/README.md`
- [x] `website/static/img/social-card.jpg`
- [x] `website/static/img/favicon.ico`
- [x] `website/static/img/logo.svg`
- [x] `website/src/components/FloatingCubes/index.tsx`
- [x] `website/src/components/FloatingCubes/styles.module.css`

**Data Files (Created):**
- [x] `website/src/data/schemas/category.schema.json`
- [x] `website/src/data/schemas/service.schema.json`
- [x] `website/src/data/schemas/stack.schema.json`
- [x] `website/src/data/stacks.json`

**Data Files (Modified):**
- [x] `website/src/data/categories.json` - converted to JSON-LD
- [x] `website/src/data/services.json` - converted to JSON-LD, added requires[]

**Category Logos (Created):**
- [x] `website/static/img/categories/ai-logo.svg`
- [x] `website/static/img/categories/authentication-logo.svg`
- [x] `website/static/img/categories/core-logo.svg`
- [x] `website/static/img/categories/databases-logo.svg`
- [x] `website/static/img/categories/datascience-logo.svg`
- [x] `website/static/img/categories/development-logo.svg`
- [x] `website/static/img/categories/management-logo.svg`
- [x] `website/static/img/categories/monitoring-logo.svg`
- [x] `website/static/img/categories/queues-logo.svg`
- [x] `website/static/img/categories/search-logo.svg`
- [x] `website/static/img/LOGO-SOURCES.md`

**Service Logos (Created):**
- [x] `website/static/img/services/*.svg` (24 SVG files)
- [x] `website/static/img/services/*.png` (4 PNG files)

**Stack Assets (Created):**
- [x] `website/static/img/stacks/observability-stack-logo.svg`
- [x] `website/static/img/stacks/ai-local-stack-logo.svg`
- [x] `website/static/img/stacks/datascience-stack-logo.svg`

**TypeScript Types (Phase 7):**
- [x] `website/src/types/service.ts`
- [x] `website/src/types/category.ts`
- [x] `website/src/types/stack.ts`
- [x] `website/src/types/index.ts`

**Utility Functions (Phase 7):**
- [x] `website/src/utils/paths.ts`
- [x] `website/src/utils/data.ts`
- [x] `website/src/utils/index.ts`

**Service & Category Components (Phase 8):**
- [x] `website/src/components/ServiceCard/index.tsx`
- [x] `website/src/components/ServiceCard/styles.module.css`
- [x] `website/src/components/ServiceGrid/index.tsx`
- [x] `website/src/components/ServiceGrid/styles.module.css`
- [x] `website/src/components/CategoryCard/index.tsx`
- [x] `website/src/components/CategoryCard/styles.module.css`
- [x] `website/src/components/CategoryGrid/index.tsx`
- [x] `website/src/components/CategoryGrid/styles.module.css`
- [x] `website/src/components/RelatedServices/index.tsx`
- [x] `website/src/components/RelatedServices/styles.module.css`

**Stack Components (Phase 9):**
- [x] `website/src/components/StackCard/index.tsx`
- [x] `website/src/components/StackCard/styles.module.css`
- [x] `website/src/components/StackGrid/index.tsx`
- [x] `website/src/components/StackGrid/styles.module.css`
- [x] `website/src/components/ServiceFlowDiagram/index.tsx`
- [x] `website/src/components/ServiceFlowDiagram/styles.module.css`

**Pages (Phase 10):**
- [x] `website/src/pages/services.tsx`
- [x] `website/src/pages/services.module.css`

**Component Exports:**
- [x] `website/src/components/index.ts`

**Other Modified:**
- [x] `website/src/pages/index.tsx` - integrate hero animation

---

## Notes

- Use SovereignSky brand colors: green #3a8f5e, teal #25c2a0, navy #1e3a5f
- SVG sources kept in `src/` subfolders for future editing
- Many service logos may be available from official project sites (check licensing)

### Logo Format Decision

**Standard for both UIS and DCT projects:**

1. **Prefer SVG** - Use SVG when available (scalable, dark mode adaptable, small files)
2. **WebP as fallback** - Convert to WebP when only raster images exist
3. **Naming convention**: `{id}-logo.svg` or `{id}-logo.webp`
4. **JSON reference** includes extension explicitly
5. **Folder structure**:
   ```
   static/img/services/
   ├── src/                    # Original source files
   ├── postgresql-logo.svg    # SVG preferred
   └── obscure-tool-logo.webp # WebP fallback
   ```

This decision will be ported back to DCT later.

### UIS Provisioning System (Reference)

The UIS automation system is simple and tested:

```
provision-host/kubernetes/
├── provision-kubernetes.sh    # Main script - loops folders and runs scripts
├── 01-core/
│   ├── 020-setup-nginx.sh     # Active - will run on first boot
│   └── not-in-use/            # Inactive scripts
├── 02-databases/
│   └── not-in-use/            # All inactive
├── 11-monitoring/
│   ├── 01-setup-prometheus.sh # Active - runs in order
│   ├── 02-setup-tempo.sh
│   ├── 03-setup-loki.sh
│   ├── 04-setup-otel-collector.sh
│   ├── 05-setup-grafana.sh
│   ├── 06-setup-testdata.sh
│   └── not-in-use/
└── ...
```

**Key points:**
- `provision-kubernetes.sh` loops through numbered folders and runs scripts in order
- Scripts in `not-in-use/` are **inactive** (not installed)
- Moving a script from `not-in-use/` to parent folder **activates** it
- Scripts run on first boot (initial provisioning)
- Script numbering within folders controls installation order
- Ansible playbooks (`ansible/playbooks/`) provide the actual deployment logic

**Folder numbering corresponds to manifest ranges:**
| Folder | Category | Manifest Range |
|--------|----------|----------------|
| 01-core | Core Infrastructure | 000-029 |
| 02-databases | Databases | 040-059 |
| 03-queues | Message Queues | 060-069 |
| 11-monitoring | Observability | 030-039 |
| 12-auth | Authentication | 070-079 |
| 07-ai | AI & ML | 200-229 |

### Data Model (Completed)

**File structure:**
```
website/src/data/
├── schemas/
│   ├── category.schema.json   # JSON Schema for categories
│   ├── service.schema.json    # JSON Schema for services
│   └── stack.schema.json      # JSON Schema for stacks
├── categories.json            # 10 service categories
├── services.json              # 28 services
└── stacks.json                # 3 service stacks
```

---

#### categories.json

JSON-LD format using schema.org `CategoryCodeSet` and `CategoryCode`.

```json
{
  "@context": "https://schema.org",
  "@type": "CategoryCodeSet",
  "name": "UIS Service Categories",
  "description": "Service categories for the Urbalurba Infrastructure Stack",
  "hasCategoryCode": [
    {
      "@type": "CategoryCode",
      "codeValue": "AI",
      "name": "AI & Machine Learning",
      "order": 1,
      "tags": ["ai", "llm", "openwebui", "ollama"],
      "abstract": "AI and machine learning services for local LLM inference.",
      "summary": "Local AI infrastructure with OpenWebUI, Ollama, and LiteLLM.",
      "logo": "ai-logo.svg",
      "manifest_range": "200-229"
    }
    // ... 9 more categories
  ]
}
```

**Categories (10 total):**
| codeValue | name | manifest_range |
|-----------|------|----------------|
| AI | AI & Machine Learning | 200-229 |
| AUTHENTICATION | Authentication & SSO | 070-079 |
| DATABASES | Databases | 040-059 |
| MONITORING | Observability & Monitoring | 030-039 |
| QUEUES | Message Queues & Caching | 060-069 |
| SEARCH | Search & Indexing | 080-089 |
| DATASCIENCE | Data Science & Analytics | 240-259 |
| CORE | Core Infrastructure | 000-029 |
| MANAGEMENT | Management Tools | 600-699 |
| DEVELOPMENT | Development Tools | 700-799 |

---

#### services.json

JSON-LD format using schema.org `ItemList` and `SoftwareApplication`.

```json
{
  "@context": "https://schema.org",
  "@type": "ItemList",
  "name": "UIS Services",
  "description": "Infrastructure services available in the Urbalurba Infrastructure Stack",
  "itemListElement": [
    {
      "@type": "SoftwareApplication",
      "identifier": "prometheus",
      "name": "Prometheus",
      "description": "Time-series metrics collection and alerting",
      "applicationCategory": "MONITORING",
      "tags": ["monitoring", "metrics", "alerting"],
      "abstract": "Pull-based metrics collection with powerful query language.",
      "logo": "prometheus-logo.svg",
      "url": "https://prometheus.io",
      "summary": "Prometheus scrapes metrics from services and stores time-series data.",
      "manifest": "031-prometheus.yaml",
      "docs": "/docs/services/monitoring/prometheus",
      "related": ["grafana", "alertmanager"],
      "requires": []
    }
    // ... 22 more services
  ]
}
```

**Service fields:**
| Field | Type | Description |
|-------|------|-------------|
| identifier | string | Unique ID (lowercase, hyphenated) |
| name | string | Display name |
| description | string | Brief description (1-2 sentences) |
| applicationCategory | string | Reference to category codeValue |
| tags | string[] | Keywords for search |
| abstract | string | One-line summary |
| logo | string | Logo filename (SVG or WebP) |
| url | string | Official project website |
| summary | string | Detailed description |
| manifest | string | Kubernetes manifest filename |
| docs | string | Path to docs within site |
| related | string[] | Related service IDs (informational) |
| requires | string[] | **Hard dependencies** (must be installed first) |

**Services with dependencies:**
| Service | requires |
|---------|----------|
| authentik | postgresql, redis |
| openwebui | ollama |
| grafana | prometheus, loki, tempo |
| pgadmin | postgresql |
| redisinsight | redis |
| jupyterhub | authentik |

---

#### stacks.json

JSON-LD format for service bundles that work together.

```json
{
  "@context": "https://schema.org",
  "@type": "ItemList",
  "name": "UIS Stacks",
  "description": "Service stacks - groups of services that work together",
  "itemListElement": [
    {
      "@type": "SoftwareSourceCode",
      "identifier": "observability",
      "name": "Observability Stack",
      "description": "Complete monitoring with metrics, logs, and traces",
      "category": "MONITORING",
      "summary": "Full visibility into your infrastructure...",
      "components": [
        { "service": "prometheus", "position": 1, "note": "Metrics collection" },
        { "service": "tempo", "position": 2, "note": "Distributed tracing" },
        { "service": "loki", "position": 3, "note": "Log aggregation" },
        { "service": "otel-collector", "position": 4, "optional": true },
        { "service": "grafana", "position": 5, "note": "Visualization" }
      ]
    }
  ]
}
```

**Stacks (3 total):**
| identifier | name | components |
|------------|------|------------|
| observability | Observability Stack | prometheus → tempo → loki → otel-collector (opt) → grafana |
| ai-local | Local AI Stack | ollama → litellm (opt) → openwebui |
| datascience | Data Science Stack | spark → jupyterhub → unity-catalog (opt) |

**Stack component fields:**
| Field | Type | Description |
|-------|------|-------------|
| service | string | Service identifier from services.json |
| position | number | Installation order (1 = first) |
| optional | boolean | If true, stack works without this component |
| note | string | Role description within the stack |

---

#### Relationship Types

1. **requires** (hard dependency)
   - Service won't function without these
   - Example: Authentik requires PostgreSQL and Redis

2. **related** (informational)
   - Services that work well together
   - Not a dependency, just helpful context

3. **stack components** (installation bundle)
   - Services installed together as a unit
   - Has installation order (position)
   - Some components may be optional

---

**Current approach:** JSON files are manually maintained.

**Future automation:** See `PLAN-002-json-generator.md` (backlog) for generating JSON from script metadata, following the DCT pattern.
