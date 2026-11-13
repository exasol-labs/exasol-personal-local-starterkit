# Troubleshooting (/data-scientist/communicate/troubleshooting)



Each entry quotes the message or describes the step that stops.

<Accordions type="multiple">
  <Accordion title="Dash Server is stopped or missing">
    The notebook installs and starts it when you call `nb.dash_tools()` or `nb.addon_ready("dash-server")`. To do it yourself, run `exakit marketplace dash-server`, then `exakit start dash-server`, then `exakit status` to confirm. See [Add-ons](/kit/tools/add-ons).
  </Accordion>

  <Accordion title="Resume the workflow before previewing or promoting">
    The dashboard belongs to the workflow it was made in. Run `nb.continue_workflow("share")` in this notebook, or resume the workflow with `nb.workflow(resume="wf-...")`, and try again.
  </Accordion>

  <Accordion title="The read-only identity is not validated, or the profile is wrong">
    The preview needs the kit's read-only user to be validated. Run `exakit mcp-doctor` to check it. When the message says the profile must validate as the read-only user, run `exakit mcp-setup`, then restart Dash Server.
  </Accordion>

  <Accordion title="The dashboard name already exists without readable lineage">
    The error reads "choose another APP_NAME". The name is taken by a dashboard the kit did not make, or one made for another dataset. Choose another `APP_NAME`. The kit never overwrites a dashboard that belongs to a different dataset.
  </Accordion>

  <Accordion title="The preview is unhealthy">
    The health check failed, so the kit will not publish it. The error reads "Dash Server preview is unhealthy". Open the Dash Server log with `exakit logs dash-server`, fix the cause, and run the preview again.
  </Accordion>

  <Accordion title="confirm asks you to open the healthy preview">
    `confirm` was called without `figures_checked=True`, or the preview is not healthy. Check the figures against the SQL, then confirm again. See [Preview, check, publish](/data-scientist/communicate/preview-check-publish).
  </Accordion>

  <Accordion title="The live dashboard failed its health check">
    The error reads "use app_rollback in Dash Server". The published revision is not healthy. Roll back there, then check the preview again before you publish another revision.
  </Accordion>

  <Accordion title="The hand-off is refused as stale">
    The training hand-off no longer matches the column map or the data. Read the line the kit prints, then write the hand-off again with `nb.write_handoff(conn, ds)`. See [A training hand-off that went stale](/data-scientist/monitor/stale-hand-off).
  </Accordion>
</Accordions>

Back to [Communicate and deploy](/data-scientist/communicate).
