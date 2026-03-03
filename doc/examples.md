# Task Examples

This page shows real prompts you can paste into Hierarchical Planner AI, along with the expected plan structure and tips for each use case.

---

## How to Use These Examples

1. Configure your LLM provider (see [Provider Setup](providers.md))
2. Copy a prompt from below into the **Task** text area
3. Click **Run Planner**
4. Review the generated plan — accept, reject, or adjust individual steps
5. Optionally assign different models to specific steps
6. Click **Run accepted steps**
7. Review the final synthesised answer

---

## 💻 Software & Engineering

### Build a REST API design

```
Design a production-ready REST API for a task management application.
Include: authentication strategy, resource endpoints (CRUD), request/response
schemas, error handling conventions, rate limiting approach, and
OpenAPI specification outline.
```

**Expected plan (~5 steps):**
1. Define data models and relationships
2. Design authentication & authorisation (JWT / OAuth2)
3. Specify resource endpoints and HTTP methods
4. Define request/response schemas and error codes
5. Outline OpenAPI spec and rate limiting strategy

---

### Code review checklist

```
Create a comprehensive code review checklist for a Python web application
using FastAPI and PostgreSQL. Cover security, performance, testing,
documentation, and maintainability concerns.
```

**Expected plan (~6 steps):**
1. Security review items (SQL injection, auth, secrets)
2. Performance and query optimisation
3. Test coverage requirements
4. API documentation standards
5. Error handling and logging
6. Code style and maintainability

---

### Database migration strategy

```
Design a zero-downtime database migration strategy for moving a PostgreSQL
monolith to a microservices architecture. The system handles 50k requests/day
and cannot have more than 30 seconds of downtime.
```

---

### Technology evaluation

```
Evaluate three JavaScript frameworks — React, Vue, and Svelte — for building
a real-time dashboard application. Compare them on: developer experience,
performance, ecosystem maturity, testing story, and bundle size. Recommend
the best choice with justification.
```

---

## 📊 Research & Analysis

### Market research report

```
Research and write a comprehensive market analysis for the AI-powered
productivity tools market in 2025. Include: market size and growth projections,
key players and their positioning, emerging trends, barriers to entry,
and opportunities for a new entrant targeting remote teams.
```

**Expected plan (~6 steps):**
1. Market size and growth data
2. Key players landscape
3. Feature and pricing comparison
4. Emerging trends and technology shifts
5. Competitive barriers
6. Opportunity analysis and recommendations

---

### Literature review

```
Write a structured literature review on the effectiveness of spaced repetition
in language learning. Cover: foundational research (Ebbinghaus), modern
studies, software implementations (Anki, Duolingo), and gaps in current
research.
```

---

### SWOT analysis

```
Conduct a detailed SWOT analysis for a traditional brick-and-mortar bookstore
considering launching an online marketplace to compete with Amazon. Include
specific, actionable insights for each quadrant.
```

---

## ✍️ Content & Writing

### Blog post series

```
Plan and draft a 4-part blog post series titled "Building AI-powered features
into your web app without a data science degree". Each post should be 800–1000
words targeting senior web developers. Include title, outline, key takeaways,
and a code example for each post.
```

**Tip**: assign a faster/cheaper model (e.g. `gpt-4o-mini`) to the research steps and a higher-quality model (`gpt-4o`) to the writing steps.

---

### Product launch announcement

```
Write a product launch communications package for a new B2B SaaS tool that
automates expense reporting using AI receipt scanning. Include: press release,
email to existing customers, LinkedIn announcement post, and FAQ document.
Target audience: finance managers at SMEs.
```

---

### Technical documentation

```
Write comprehensive user documentation for a CLI tool called "dbmigrate" that
manages database schema migrations. Cover: installation, quickstart, all
commands with examples, configuration file reference, and common error messages
with solutions.
```

---

## 🎯 Planning & Strategy

### Project plan

```
Create a detailed project plan for launching a mobile app MVP in 12 weeks
with a team of 3 developers, 1 designer, and 1 product manager. Include:
week-by-week milestones, risk register, team responsibilities, definition
of done for MVP, and launch checklist.
```

**Expected plan (~5 steps):**
1. Scope definition and MVP feature list
2. Week-by-week timeline and milestones
3. Team responsibilities and RACI matrix
4. Risk register and mitigation strategies
5. Launch checklist and go-live criteria

---

### Learning curriculum

```
Design a 3-month self-study curriculum for a software developer to become
proficient in machine learning. Assume Python knowledge but no ML background.
Include weekly topics, recommended resources (books, courses, projects),
and milestone projects to build a portfolio.
```

---

### Business process improvement

```
Analyse and redesign the customer onboarding process for a SaaS company.
Current process takes 14 days and has a 30% drop-off rate. Propose
improvements targeting: <7 days to value, <10% drop-off, automated
touchpoints, and measurable success metrics.
```

---

## 🔬 Science & Learning

### Explain a complex topic

```
Explain quantum computing to a software developer with no physics background.
Cover: what problem it solves, how qubits differ from bits, superposition and
entanglement (with analogies), current limitations, practical applications
in the next 10 years, and how a developer can start learning more.
```

---

### Study guide

```
Create a comprehensive study guide for the AWS Solutions Architect Associate
exam. Include: all exam domains with weight, key services to master per domain,
common trick questions and how to approach them, a 4-week study plan,
and a practice question set for each domain.
```

---

## 💡 Tips for Better Results

### Write clear, specific prompts

| ❌ Vague | ✅ Specific |
|---|---|
| "Research AI" | "Research the top 5 open-source LLM frameworks for production deployment in 2025, comparing ease of use, performance, and community support" |
| "Write a plan" | "Write a 90-day onboarding plan for a new senior backend engineer joining a fintech startup" |
| "Analyse this topic" | "Analyse the pros and cons of event sourcing vs traditional CRUD for a high-volume e-commerce order management system" |

### Scope your task appropriately

- **Too broad**: "Write a complete e-commerce platform" — the planner will create steps that are individually too large for one LLM call
- **Too narrow**: "Write a function to sort a list" — doesn't benefit from multi-agent decomposition; just use a regular chat
- **Just right**: Tasks that naturally break into 3–8 distinct parallel workstreams

### Per-step model assignment

After the plan is generated, use the model dropdown on each step card to:
- Assign a **cheap/fast model** to factual research steps
- Assign a **high-quality model** to synthesis, writing, or reasoning-heavy steps
- Keep the **Aggregator** on a quality model since it writes the final answer

### Handling slow local models

If using Jan.ai or Ollama with a large model:
- Set **Chain retries** to `1` to avoid triple-length timeouts
- Use **Cancel** if a step is stuck, then retry just that step
- Consider using a smaller quantised model (Q4 vs Q8) for faster inference
