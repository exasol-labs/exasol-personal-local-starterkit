# The data science workflow (/data-scientist)



Most data science work is not a straight line. You set up, load the data, look at it, prepare it, model it and check the result. Then a finding in a later stage sends you back. A column you trusted turns out to give away the answer, so you prepare the data again. Treat the eight stages as a loop, not a checklist.

Choose a stage to read its page. Each page says what the stage is for, where you do it in the kit, a worked example on the kit's sample data, and what can go wrong.

<StageMap />

## How the kit fits in [#how-the-kit-fits-in]

The kit runs this workflow on an Exasol database on your computer. Four notebooks take you through the stages in order. Each notebook continues the same workflow, so you paste no id and copy nothing between them.

<Flow
  caption="The four notebooks, in order, and the stages each one covers"
  steps="[
  { title: &#x22;00_quickstart&#x22;, text: &#x22;Set up Exasol, Get the data, and the column map of Explore and understand&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/set-up&#x22; },
  { title: &#x22;01_explore&#x22;, text: &#x22;Prepare, Explore, Model and Evaluate&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/prepare&#x22; },
  { title: &#x22;02_ask_your_data&#x22;, text: &#x22;Explore and understand: asking questions in plain language&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/explore&#x22; },
  { title: &#x22;03_share&#x22;, text: &#x22;Communicate and deploy: a dashboard and a hand-off folder&#x22;, tone: &#x22;kit&#x22;, href: &#x22;/data-scientist/communicate&#x22; },
]"
/>

Monitor and iterate has no notebook of its own. The workflow log records what you did, and you iterate by changing the column map or the data and running the notebooks again. The notebooks read the newest approval.

## Two ways through each notebook [#two-ways-through-each-notebook]

Every notebook opens with a **guided card**. A card has buttons and forms for the page's steps. Each card has a **Guided / Code** switch at its top right.

* **Guided** is the default. You click, choose and approve.
* **Code** turns the same card into its code as cells. Each cell shows the exact `exakit.nb` call behind a control. You can edit and run those cells.

Every button is one call, so clicking **Approve** and running the approve call do the same thing. The notebook's own code sits below the cards. You can use either way, or switch between them as you work.

## Developers [#developers]

If you build on the kit, or want the commands behind the notebooks, see [For developers](/data-scientist/development). It has the command reference, how the cards and helpers fit together, and where the kit keeps its files.
