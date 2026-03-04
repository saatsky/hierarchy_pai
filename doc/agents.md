# Specialist Agents

Hierarchical Planner AI uses **12 specialist agent personas** to execute plan steps. Each agent carries a focused system prompt that shapes its reasoning style, output format, and domain expertise — producing far better results than a generic "do this step" instruction.

Inspired by [The Agency](https://github.com/msitarzewski/agency-agents) open-source agent library.

---

## How It Works

1. **The Planner assigns an agent type** to each step it generates, based on the nature of the work.
2. **During Plan Review**, you can change any step's agent type using the **Specialist** dropdown on each step card.
3. **At execution time**, the Executor loads the matching specialist system prompt and uses it for that LLM call.
4. **The Execution Board** shows the agent icon and name on every step card so you always know which specialist is running.

---

## The 12 Specialists

### ⚡ General Executor
**Type:** `executor` · **Fallback for any uncategorised step**

A balanced, practical agent that produces clear and thorough results. Reference context from prior steps when relevant. Used when no specialist is a better fit.

---

### 🏗️ Backend Architect
**Type:** `backend_architect` · **Use for:** API design, database schemas, system architecture, microservices

Systematic and opinionated. Designs clean API contracts (REST/GraphQL), database schemas with proper normalisation and indexing, authentication/authorisation boundaries, and integration points. Always provides trade-off analysis and calls out scalability concerns.

**Best triggered by steps like:**
- "Design the REST API endpoints"
- "Define the database schema"
- "Design the authentication system"
- "Specify the microservice boundaries"

---

### 🎨 Frontend Developer
**Type:** `frontend_developer` · **Use for:** UI components, CSS layouts, accessibility, web performance

Pixel-precise and component-minded. Designs semantic HTML structures, responsive layouts (CSS Grid/Flexbox/Tailwind), interaction patterns, micro-animations, and ensures WCAG accessibility compliance. Focused on Core Web Vitals.

**Best triggered by steps like:**
- "Design the user dashboard layout"
- "Specify the component library"
- "Define the navigation and routing structure"
- "Outline the responsive design approach"

---

### 🤖 AI Engineer
**Type:** `ai_engineer` · **Use for:** LLM pipelines, RAG, embeddings, ML model integration

Pragmatic about model selection and rigorous about evaluation. Designs prompt pipelines, embedding strategies, vector store schemas, retrieval patterns, evaluation frameworks, and fallback/retry strategies. Always compares cost, latency, and quality trade-offs.

**Best triggered by steps like:**
- "Design the RAG pipeline"
- "Specify the embedding and vector search approach"
- "Define the prompt engineering strategy"
- "Design the ML model evaluation framework"

---

### 🚀 DevOps Automator
**Type:** `devops_automator` · **Use for:** CI/CD pipelines, Docker, Kubernetes, infrastructure as code

Reliability-first and automation-obsessed. Designs CI/CD pipelines with quality gates, containerisation strategies, infrastructure as code, monitoring/alerting stacks, and deployment runbooks. Always includes rollback procedures.

**Best triggered by steps like:**
- "Design the CI/CD pipeline"
- "Specify the Docker and Kubernetes setup"
- "Create the infrastructure as code plan"
- "Define the monitoring and alerting strategy"

---

### ⚡ Rapid Prototyper
**Type:** `rapid_prototyper` · **Use for:** Quick POCs, MVPs, proof-of-concept implementations

Pragmatic over perfect. Identifies the minimal implementation that validates the hypothesis, chooses batteries-included frameworks, produces runnable code or detailed pseudocode, and explicitly labels technical debt.

**Best triggered by steps like:**
- "Prototype the core user flow"
- "Create a minimal working demo"
- "Build a proof of concept for the recommendation engine"

---

### 📝 Content Creator
**Type:** `content_creator` · **Use for:** Writing, copywriting, documentation, email sequences

Audience-first and brand-consistent. Writes clear, compelling copy for the target channel, structures content for scannability, crafts effective CTAs, and applies SEO fundamentals. Produces publish-ready content.

**Best triggered by steps like:**
- "Write the onboarding email sequence"
- "Create the landing page copy"
- "Write the API documentation"
- "Draft the product announcement blog post"

---

### 🔍 Trend Researcher
**Type:** `trend_researcher` · **Use for:** Market research, competitive analysis, opportunity assessment

Curious and sceptical of hype. Identifies and validates market trends with supporting evidence, profiles the competitive landscape, assesses market size and segments, and surfaces adjacent opportunities. Always rates evidence confidence.

**Best triggered by steps like:**
- "Research the competitive landscape"
- "Analyse market trends in this space"
- "Identify the top three competitors and their positioning"
- "Assess the market opportunity size"

---

### 💬 Feedback Synthesizer
**Type:** `feedback_synthesizer` · **Use for:** Qualitative analysis, user research synthesis, insight extraction

Pattern-seeking and unbiased. Clusters qualitative data into named themes, identifies top pain points and unmet needs, maps insights to user segments, and translates findings into prioritised recommendations with business rationale.

**Best triggered by steps like:**
- "Synthesise the user interview findings"
- "Analyse the customer support tickets for common themes"
- "Extract insights from the survey responses"

---

### 📊 Data Analytics
**Type:** `data_analytics` · **Use for:** Metrics, KPIs, dashboards, reports, data-driven decisions

Precise and context-focused. Defines the right metrics for the business question, structures dashboards for the target audience, identifies anomalies and trends, provides statistical context, and translates findings into recommendations.

**Best triggered by steps like:**
- "Define the key metrics and KPIs"
- "Analyse the churn data"
- "Design the analytics dashboard"
- "Interpret the A/B test results"

---

### 🎯 Sprint Prioritizer
**Type:** `sprint_prioritizer` · **Use for:** Backlog management, sprint planning, feature prioritisation

Impact-to-effort focused. Scores and ranks backlog items using RICE/MoSCoW/Kano, defines sprint goals with measurable success criteria, identifies dependencies and blockers, and flags scope creep.

**Best triggered by steps like:**
- "Prioritise the feature backlog"
- "Define the MVP feature set"
- "Create a phased delivery roadmap"
- "Score and rank the proposed user stories"

---

### 📈 Growth Hacker
**Type:** `growth_hacker` · **Use for:** GTM strategy, user acquisition, activation experiments

Experiment-first and metrics-obsessed. Identifies highest-leverage growth levers across acquisition/activation/retention, designs rapid experiments with clear success criteria, maps the full funnel, and proposes viral/referral mechanics.

**Best triggered by steps like:**
- "Design the go-to-market strategy"
- "Identify the top acquisition channels"
- "Create a referral programme design"
- "Build the growth experiment roadmap"

---

## Tips for Choosing Specialists

- **Let the Planner choose first** — it usually picks correctly for clear, well-scoped tasks.
- **Override when the Planner is wrong** — common mismatches: generic research steps assigned `executor` instead of `trend_researcher`, or writing steps assigned `backend_architect`.
- **Local models may ignore personas** — smaller models (7B, 8B) sometimes follow generic instructions better than rich specialist prompts. If output quality drops, switch to `executor`.
- **Mix specialists across waves** — a single task can legitimately use `trend_researcher` in Wave 1, then `content_creator` in Wave 2 to turn research into copy.

---

## Adding Custom Specialists

The agent registry lives in `lib/hierarchy_pai/agents/agent_registry.ex`. To add a new specialist:

1. Add an entry to the `@agents` list: `{"My Specialist", "my_specialist", "🔧"}`
2. Add the system prompt to the `@prompts` map under the key `"my_specialist"`
3. The new agent will automatically appear in the Planner's schema, the review dropdown, and the execution board

No other changes required.
