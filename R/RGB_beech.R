"""
ACT group 10
Remote Sensing and GIS Integration 2020
Title: Forest Inventory through UAV based remote sensing
Description: This script can be used to compute the standing volume for beech from AHN3 and UAV RGB data.
At the end of the script some validation with TLS data is performed. 

"""

# Loading the required libraries
library(lidR)
library(raster)
library(colorRamps)
library(sp)
library(rgl)
library(rlas)
library(tiff)
library(itcSegment)
library(ForestTools)

readLAS<-lidR::readLAS

## Setting working directory
setwd("../ACT_Forest_Inventory")

#### CHM COMPUTATION ####
set.seed(2020)

# Load and read the AHN3 file
AHN3_clip <- "Data/AHN3.laz"
AHN3 <- readLAS(AHN3_clip)
x <-  c(176254, 176185, 176167, 176236)
y <- c(473741, 473712, 473754, 473783)
AHN3 <- lasclipPolygon(AHN3, x, y, inside=TRUE)

# We compute two DTMs modifying just one parameter (keep lowest)
DTM1 <- grid_terrain(AHN3, res=1, algorithm = knnidw(k=6L, p = 2), keep_lowest = FALSE)
DTM2 <- grid_terrain(AHN3, res=1, algorithm = knnidw(k=6L, p = 2), keep_lowest=TRUE)

# We plot both DTMs to observe the differences
plot(DTM1, main="DTM1", col=matlab.like2(50))
plot(DTM2, main="DTM2", col=matlab.like2(50))

# We compute the differences between DTM and create and histogram to check if they are close to 0
Difference <- DTM2 - DTM1
plot(Difference, main="Difference", col=matlab.like2(50))
hist(Difference)
# As the values are almost the same (all around 0 in the difference), we will work with the first DTM (DTM1)

# We load the DSM created with photogrammetry from RGB images, we project it to RD New and resample to 
# have the same resolution as the DTM
RGB <- "Data/DEM_speulderbos_georef_ar.tif"
DSM_no_proj <- raster(RGB)
DSM_proj <- projectRaster(DSM_no_proj, crs = crs(DTM1))
DSM <- resample(DSM_proj, DTM1, method = "bilinear")

# Compute the CHM substracting also 40.68, which is the difference height between the DSM and the DTM
# in the area on the left (U-shaped area) and plot if needed.
CHM <- DSM - DTM1 - 40.68
# plot(CHM, main="CHM", col=matlab.like2(50), xaxt="n", yaxt="n")

#Remove NA values
CHM[is.na(CHM)] <- 0

# Use the focal statistics to smooth the CHM
CHM_smooth <- focal(CHM,w=matrix(1/9, nc=3, nr=3), na.rm=TRUE)
plot(CHM_smooth)

#### CHM DERIVATES COMPUTATION ####

# Use the Variable Window Filter (VWF) to detect dominant tree tops. We use a linear function used in 
# forestry and set the minimum height of trees at 10, but those variables can be modified. 
# After this we plot it to check how the tree tops look like. 
lin <- function(x) { x * 0.02 + 0.5 }
treetops <- vwf(CHM = CHM_smooth, winFun = lin, minHeight = 20)
plot(CHM, main="CHM", col=matlab.like2(50), xaxt="n", yaxt="n")
plot(treetops, col="black", pch = 20, cex=0.5, add=TRUE)

# Check the mean of the height of the detected tree tops 
mean(treetops$height)

# Use the function MCWS function that implements the watershed algorithm to produce a map of crowns. 
# In this case, the argument minHeight refers to the lowest expected treetop. The result is a raster 
# where each tree crown is a unique cell value. 
crowns <- mcws(treetops = treetops, CHM=CHM_smooth, minHeight = 15, verbose=FALSE)
plot(crowns, main="Detected tree crowns", col=sample(rainbow(50), length(unique(crowns[])),replace=TRUE), 
     legend=FALSE, xaxt="n", yaxt="n")

# Use the  the MCWS function that implements the watershed algorithm to produce a map of crowns as polygons. It takes more processing
# time but polygons inherit the attributes of treetops as height. Also, crown area is computed for each polygon.
crownsPoly <- mcws(treetops = treetops, CHM=CHM_smooth, minHeight = 15, verbose=FALSE, format="polygons")
plot(CHM, main="CHM", col=matlab.like2(50), xaxt="n", yaxt="n")
plot(crownsPoly, border="black", lwd=0.5, add=TRUE)

# Assuming each crown has a roughly circular shape,the crown area is used to compute its average circular diameter.
crownsPoly[["crownDiameter"]] <- sqrt(crownsPoly$crownArea/pi) *2
mean(crownsPoly$crownDiameter)
mean(crownsPoly$crownArea)

sp_summarise(treetops)
sp_summarise(crownsPoly, variables=c("crownArea", "height"))

#### DBH AND TREE VOLUME ESTIMATION ####

# Compute the DBH based on the tree height in m and crown diameter in m^2, adapted to the type of biome.
crownsPoly$DBH <- dbh(H=crownsPoly$height, CA = crownsPoly$crownDiameter, biome=20)/100

# Compute the standing volume in m^3 from the DBH in cm and the height in m. Source: https://silvafennica.fi/pdf/smf004.pdf
crownsPoly$standing_volume <- ((0.049)*((crownsPoly$DBH*100)^1.78189)*(crownsPoly$height)^1.08345)/1000
hist(crownsPoly$standing_volume)

# Save the results to a csv file.
dataset <- as.data.frame(crownsPoly)
write.csv(dataset,"Data/photogrammetry_beech.csv", row.names = TRUE)

# Compute the total tree volume in m^3
totalVolume <- sum(as.matrix(crownsPoly$standing_volume))
emptyArea <- 240                                       # area of empty spaces in the forest measured with polygons in ArcgIS/QGIS
totalArea <- raster::area(AHN3) - emptyArea            # area of forest
m3ha <- totalVolume/(totalArea/10000)                  # total tree volume in m^3 per hectare
m3ha

##### VALIDATION ####

# Read the excels generated above and in the TLS scripts
TLS_dataset <- read.csv("Data/TLS_beech.csv", header=TRUE, sep = ",")
UAV_LS_dataset <- read.csv("Data/photogrammetry_beech.csv", header=TRUE, sep = ",")

# Compute some statistics of both datasets
trees_UAV <- nrow(UAV_LS_dataset)
trees_TLS <- nrow(TLS_dataset)
trees_ha_UAV <- trees_UAV/(totalArea/10000)
trees_ha_TLS <- trees_TLS/(totalArea/10000)
mean_height_UAV <- mean(UAV_LS_dataset$height)
mean_height_TLS <- mean(TLS_dataset$height)
mean_DBH_UAV <- mean(UAV_LS_dataset$DBH)
mean_DBH_TLS <- mean(TLS_dataset$DBH)
m3ha_TLS <- sum(TLS_dataset$standing_volume)/(totalArea/10000)

# Compare if there is a significant difference between the DBH from TLS and UAV-LS
t_test_DBH <- t.test(TLS_dataset$DBH, UAV_LS_dataset$DBH, 
                     paired = FALSE, alternative = "two.sided")

mean_volume_UAV <- mean(UAV_LS_dataset$standing_volume)
mean_volume_TLS <- mean(TLS_dataset$standing_volume)

# Compare if there is a significant difference between the standing volume from TLS and UAV-LS
t_test_volume <- t.test(TLS_dataset$standing_volume, UAV_LS_dataset$standing_volume, 
                        paired = FALSE, alternative = "two.sided")


validation_results <- data.frame("Dataset" = c("UAV", "TLS"), "Number of trees" = c(trees_UAV, trees_TLS), 
                                 "Trees per ha" = c(trees_ha_UAV, trees_ha_TLS), "Mean height" = c(mean_height_UAV, mean_height_TLS),
                                 "Mean DBH" = c(mean_DBH_UAV, mean_DBH_TLS), "t-test DBH" = t_test_DBH$p.value,
                                 "CI DBH" =t_test_DBH$conf.int,"St error DBH" = t_test_DBH$stderr,
                                 "Mean volume" = c(mean_volume_UAV, mean_volume_TLS),"t-test volume" = t_test_volume$p.value,
                                 "CI volume"=t_test_volume$conf.int,"St error volume" = t_test_volume$stderr, "m^3 per ha" = c(m3ha, m3ha_TLS))


# Export the results in an excel
write.table(validation_results, "Data/validation_results_RGB_beech.csv", row.names = TRUE)
