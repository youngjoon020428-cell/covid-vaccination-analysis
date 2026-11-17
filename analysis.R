# COVID-19 Vaccination and Death Rates: R code extracted from project_final_report.Rmd
# Run from the repository root after placing owid-covid-data.csv in data/ (see data/README.md).
# The full write-up with figures is in project_final_report.Rmd / project_final_report.html.

## ----setup, include=FALSE-----------------------------------------------------
knitr::opts_chunk$set(echo = FALSE, message = FALSE, warning = FALSE, error = FALSE,
                      fig.width = 7, fig.height = 4.5)

library(tidyverse)
library(modelr)
library(broom)
library(knitr)

# Small helpers for reporting numbers in the text
fmt_p   <- function(p) format.pval(p, digits = 2, eps = 1e-4)
fmt_b   <- function(b, d = 4) formatC(b, format = "f", digits = d)
pct_10  <- function(b) round((exp(10 * b) - 1) * 100, 1)   # % change in Y per +10 doses per hundred


## ----load-data----------------------------------------------------------------
# Put owid-covid-data.csv in the data/ folder (see data/README.md)
data_orig <- read_csv("data/owid-covid-data.csv")

# Aggregate rows (continents, income groups, World, EU) have no continent value,
# so keeping rows with a continent keeps only individual countries/territories.
countries_daily <- data_orig %>%
  filter(!is.na(continent)) %>%
  select(iso_code, continent, location, date,
         total_vaccinations_per_hundred, total_deaths_per_million, total_cases_per_million,
         aged_65_older, gdp_per_capita)

# One row per country: the latest (= maximum) value of each cumulative measure
country_df <- countries_daily %>%
  group_by(location, continent) %>%
  summarize(
    vax_per_hundred   = max(total_vaccinations_per_hundred, na.rm = TRUE),
    deaths_per_million = max(total_deaths_per_million, na.rm = TRUE),
    cases_per_million  = max(total_cases_per_million, na.rm = TRUE),
    aged_65_older     = first(na.omit(aged_65_older)),
    gdp_per_capita    = first(na.omit(gdp_per_capita)),
    .groups = "drop"
  ) %>%
  filter(is.finite(vax_per_hundred), is.finite(deaths_per_million), is.finite(cases_per_million),
         deaths_per_million > 0, cases_per_million > 0)   # needed for the log transform

n_countries <- nrow(country_df)
last_date   <- max(data_orig$date)


## ----world-trend--------------------------------------------------------------
world_data <- data_orig %>%
  filter(location == "World") %>%
  select(date, new_vaccinations_smoothed, new_deaths_smoothed) %>%
  pivot_longer(-date, names_to = "series", values_to = "value") %>%
  filter(!is.na(value), value > 0) %>%
  mutate(series = recode(series,
                         new_vaccinations_smoothed = "Daily vaccine doses",
                         new_deaths_smoothed = "Daily deaths"))

ggplot(world_data, aes(x = date, y = value, color = series)) +
  geom_line() +
  scale_y_log10(labels = scales::comma) +
  scale_color_manual(values = c("Daily vaccine doses" = "black", "Daily deaths" = "red")) +
  labs(title = "World: Daily Vaccine Doses and COVID-19 Deaths (7-day average)",
       x = NULL, y = "Count (log scale)", color = NULL) +
  theme_minimal() +
  theme(legend.position = "bottom")


## ----scatter-deaths-----------------------------------------------------------
ggplot(country_df, aes(x = vax_per_hundred, y = deaths_per_million)) +
  geom_point(alpha = 0.5) +
  geom_smooth(method = "lm", se = TRUE) +
  scale_y_log10(labels = scales::comma) +
  labs(title = "Vaccination Rate vs. COVID-19 Death Rate by Country",
       x = "Total Vaccine Doses per Hundred",
       y = "Total Deaths per Million (log scale)")


## ----scatter-cases------------------------------------------------------------
ggplot(country_df, aes(x = vax_per_hundred, y = cases_per_million)) +
  geom_point(alpha = 0.5) +
  geom_smooth(method = "lm", se = TRUE) +
  scale_y_log10(labels = scales::comma) +
  labs(title = "Vaccination Rate vs. COVID-19 Case Rate by Country",
       x = "Total Vaccine Doses per Hundred",
       y = "Total Cases per Million (log scale)")


## ----simple-models------------------------------------------------------------
m_deaths <- lm(log(deaths_per_million) ~ vax_per_hundred, data = country_df)
m_cases  <- lm(log(cases_per_million)  ~ vax_per_hundred, data = country_df)

model_row <- function(model, label, term = "vax_per_hundred") {
  tidy(model) %>%
    filter(term == !!term) %>%
    transmute(Model = label,
              `β (vaccination)` = estimate,
              SE = std.error,
              `t` = statistic,
              `p-value` = fmt_p(p.value),
              `R²` = glance(model)$r.squared,
              n = nobs(model))
}

bind_rows(model_row(m_deaths, "log(deaths/million) ~ vaccination"),
          model_row(m_cases,  "log(cases/million) ~ vaccination")) %>%
  kable(digits = 4)

b_d  <- coef(m_deaths)["vax_per_hundred"];  p_d  <- tidy(m_deaths)$p.value[2]
b_c  <- coef(m_cases)["vax_per_hundred"];   p_c  <- tidy(m_cases)$p.value[2]
r2_d <- glance(m_deaths)$r.squared;         r2_c <- glance(m_cases)$r.squared


## ----residuals, fig.height = 6------------------------------------------------
diag_df <- bind_rows(
  country_df %>% add_residuals(m_deaths) %>% add_predictions(m_deaths) %>% mutate(model = "Deaths model"),
  country_df %>% add_residuals(m_cases)  %>% add_predictions(m_cases)  %>% mutate(model = "Cases model")
)

p1 <- ggplot(diag_df, aes(x = pred, y = resid)) +
  geom_point(alpha = 0.5) +
  geom_hline(yintercept = 0, color = "red", linetype = "dashed") +
  facet_wrap(~ model, scales = "free_x") +
  labs(x = "Fitted values", y = "Residuals", title = "Residuals vs. Fitted")

p2 <- ggplot(diag_df, aes(sample = resid)) +
  stat_qq(alpha = 0.5) +
  stat_qq_line(color = "red") +
  facet_wrap(~ model) +
  labs(x = "Theoretical quantiles", y = "Sample quantiles", title = "Normal Q-Q Plot")

print(p1)
print(p2)


## ----confounders--------------------------------------------------------------
country_df %>%
  summarize(
    `vaccination vs. % aged 65+` = cor(vax_per_hundred, aged_65_older, use = "complete.obs"),
    `vaccination vs. log GDP per capita` = cor(vax_per_hundred, log(gdp_per_capita), use = "complete.obs"),
    `log deaths vs. % aged 65+` = cor(log(deaths_per_million), aged_65_older, use = "complete.obs"),
    `log deaths vs. log GDP per capita` = cor(log(deaths_per_million), log(gdp_per_capita), use = "complete.obs")
  ) %>%
  pivot_longer(everything(), names_to = "Pair", values_to = "Correlation") %>%
  kable(digits = 3)


## ----adjusted-models----------------------------------------------------------
adj_df <- country_df %>% drop_na(aged_65_older, gdp_per_capita)

m_deaths_adj <- lm(log(deaths_per_million) ~ vax_per_hundred + aged_65_older + log(gdp_per_capita), data = adj_df)
m_cases_adj  <- lm(log(cases_per_million)  ~ vax_per_hundred + aged_65_older + log(gdp_per_capita), data = adj_df)

tidy(m_deaths_adj) %>%
  mutate(p.value = fmt_p(p.value)) %>%
  kable(digits = 4, caption = "Adjusted model: log(deaths per million)")

tidy(m_cases_adj) %>%
  mutate(p.value = fmt_p(p.value)) %>%
  kable(digits = 4, caption = "Adjusted model: log(cases per million)")

b_da <- coef(m_deaths_adj)["vax_per_hundred"]; p_da <- tidy(m_deaths_adj)$p.value[2]
b_ca <- coef(m_cases_adj)["vax_per_hundred"];  p_ca <- tidy(m_cases_adj)$p.value[2]
r2_da <- glance(m_deaths_adj)$r.squared;       r2_ca <- glance(m_cases_adj)$r.squared


## ----lag-model----------------------------------------------------------------
cutoff <- as.Date("2021-12-31")

lag_df <- countries_daily %>%
  group_by(location) %>%
  summarize(
    vax_2021      = suppressWarnings(max(total_vaccinations_per_hundred[date <= cutoff], na.rm = TRUE)),
    deaths_2021   = suppressWarnings(max(total_deaths_per_million[date <= cutoff], na.rm = TRUE)),
    deaths_final  = suppressWarnings(max(total_deaths_per_million, na.rm = TRUE)),
    aged_65_older = first(na.omit(aged_65_older)),
    gdp_per_capita = first(na.omit(gdp_per_capita)),
    .groups = "drop"
  ) %>%
  mutate(deaths_after_2021 = deaths_final - deaths_2021) %>%
  filter(is.finite(vax_2021), is.finite(deaths_after_2021), deaths_after_2021 > 0) %>%
  drop_na(aged_65_older, gdp_per_capita)

m_lag     <- lm(log(deaths_after_2021) ~ vax_2021, data = lag_df)
m_lag_adj <- lm(log(deaths_after_2021) ~ vax_2021 + aged_65_older + log(gdp_per_capita), data = lag_df)

bind_rows(model_row(m_lag,     "Unadjusted", term = "vax_2021"),
          model_row(m_lag_adj, "Adjusted for age + GDP", term = "vax_2021")) %>%
  kable(digits = 4, caption = "Vaccination by end of 2021 vs. log(deaths per million after 2021)")


## ----summary-table------------------------------------------------------------
bind_rows(
  model_row(m_deaths,     "Deaths: unadjusted"),
  model_row(m_deaths_adj, "Deaths: adjusted"),
  model_row(m_cases,      "Cases: unadjusted"),
  model_row(m_cases_adj,  "Cases: adjusted"),
  model_row(m_lag,        "Deaths after 2021: unadjusted", term = "vax_2021"),
  model_row(m_lag_adj,    "Deaths after 2021: adjusted",   term = "vax_2021")
) %>%
  mutate(`Decision (α = 0.05)` = if_else(as.numeric(str_remove(`p-value`, "<")) < 0.05,
                                         "Reject H0", "Fail to reject H0")) %>%
  kable(digits = 4)

