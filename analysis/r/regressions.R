

models <-
    list(
        feols(z_embedding_shift ~ changed_top_choice,
              data = analysis_df),
        feols(changed_top_choice ~ log_user_word_count,
              data = analysis_df),
        feols(changed_top_choice ~ z_log_user_word_count,
              data = analysis_df),
        feols(changed_top_choice ~ duration_minutes,
              data = analysis_df),
        feols(changed_top_choice ~ z_duration_minutes,
              data = analysis_df),
        feols(changed_top_choice ~ assistant_question_count,
              data = analysis_df),
        feols(changed_top_choice ~ assistant_question_count,
              data = analysis_df)
        # feols(applied ~ treatment_group*white + age_clean + white + male | county,
        #       data = full_data, cluster = ~university)
    )

modelsummary(
    models,
    stars = c('*' = .1, '**' = .05, '***' = .01),
    output = 'kableExtra',
    # gof_map = gof_map,
    # notes = model_notes,
    # coef_map = c(
    #     "(Intercept)" = "Intercept",
    #     "treatment_groupinfo" = "Treatment: Info",
    #     'treatment_groupnorms' = 'Treatment: Norms',
    #     'age_clean' = 'Age',
    #     'white' = 'White',
    #     'male' = 'Male',
    #     'treatment_groupinfo:white' = 'Treatment: Info × white',
    #     'treatment_groupnorms:white' = 'Treatment: Norms × white'),
    escape = TRUE,
) %>%
    # add_header_above(c(" " = 1, "(1)" = 1, "(2)" = 1, "(3)" = 1, "(4)" = 1, "(5)" = 1, "(6)" = 1)) %>% 
    row_spec(0, extra_css = "display: none;")


